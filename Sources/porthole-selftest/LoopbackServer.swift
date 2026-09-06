import Foundation
import PortholeCore

/// A minimal RFB 3.8 server that speaks just enough to exercise the client
/// end-to-end over a real TCP socket: handshake, ServerInit, framebuffer
/// updates and the resize round trip. Nothing here shares code with the
/// client, so the two have to agree on the wire format rather than on a
/// shared helper.
final class LoopbackServer {
    private var preferredPort: UInt16 = 0
    private var listenFD: Int32 = -1
    private var clientFD: Int32 = -1
    private(set) var port: UInt16 = 0

    let width: Int
    let height: Int
    /// Security types to offer; the client should pick `none` when present.
    var offeredSecurity: [UInt8] = [1]
    var desktopName = "loopback"

    /// Set once the client asks for a specific size.
    private(set) var requestedSize: (Int, Int)?
    private(set) var sawSetPixelFormat = false
    private(set) var sawEncodings: [Int32] = []
    private(set) var receivedKeys: [(UInt32, Bool)] = []
    private(set) var receivedPointers: [(Int, Int, UInt8)] = []
    /// Set if the client ever sends an incremental update request while it has
    /// continuous updates enabled — the combination that wedges neatvnc.
    private(set) var sawIncrementalWhileContinuous = false
    private var continuousUpdatesEnabled = false
    /// Reply to EnableContinuousUpdates(1) with EndOfContinuousUpdates, the way
    /// the real server was observed to, without clearing our own flag.
    var endContinuousUpdatesOnEnable = false
    /// Announce extended-clipboard capabilities on connect, the way neatvnc
    /// does — including its refusal to accept unsolicited content.
    var announceExtClipboard = false
    private(set) var extClipboardText: String?
    private(set) var sawClipboardNotify = false
    private var pendingServerClipboard: String?
    private let lock = NSLock()
    /// Frames may be pushed from a timer while the message loop reads, so
    /// writes need their own lock.
    private let sendLock = NSLock()
    /// Mutable so the demo server can honour a client resize request.
    var currentSize: (Int, Int)
    /// Invoked when the client asks for a new desktop size.
    var onResize: ((Int, Int) -> Void)?

    init(width: Int, height: Int, preferredPort: UInt16 = 0) throws {
        self.preferredPort = preferredPort
        self.width = width
        self.height = height
        self.currentSize = (width, height)
        try openListener()
    }

    private func openListener() throws {
        listenFD = socket(AF_INET, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw HarnessError.failed("socket() failed") }
        var one: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = preferredPort.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw HarnessError.failed("bind() failed") }
        guard listen(listenFD, 1) == 0 else { throw HarnessError.failed("listen() failed") }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listenFD, $0, &length)
            }
        }
        port = UInt16(bigEndian: actual.sin_port)
    }

    /// Runs the server conversation on a background thread. With `repeatedly`
    /// it serves one client after another, which is what the demo mode wants;
    /// the tests use a single connection and let the process exit.
    func start(repeatedly: Bool = false, onReady: @escaping () -> Void) {
        let thread = Thread { [weak self] in
            guard let self else { return }
            repeat {
                do {
                    let fd = accept(self.listenFD, nil, nil)
                    guard fd >= 0 else { return }
                    var one: Int32 = 1
                    setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &one,
                               socklen_t(MemoryLayout<Int32>.size))
                    self.sendLock.lock()
                    self.clientFD = fd
                    self.sendLock.unlock()
                    try self.handshake()
                    onReady()
                    try self.serve()
                } catch {
                    // A client closing first is the normal end of a session.
                }
                self.sendLock.lock()
                if self.clientFD >= 0 { Foundation.close(self.clientFD); self.clientFD = -1 }
                self.sendLock.unlock()
            } while repeatedly
        }
        thread.name = "loopback.server"
        thread.start()
    }

    // MARK: - Wire helpers

    func send(_ bytes: [UInt8]) throws {
        sendLock.lock()
        defer { sendLock.unlock() }
        let clientFD = self.clientFD
        guard clientFD >= 0 else { throw HarnessError.failed("no client") }
        var offset = 0
        try bytes.withUnsafeBytes { raw in
            while offset < raw.count {
                let n = write(clientFD, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n > 0 { offset += n; continue }
                if n < 0 && errno == EINTR { continue }
                throw HarnessError.failed("server write failed")
            }
        }
    }

    private func recv(_ count: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        var got = 0
        try out.withUnsafeMutableBytes { raw in
            while got < count {
                let n = read(clientFD, raw.baseAddress!.advanced(by: got), count - got)
                if n > 0 { got += n; continue }
                if n < 0 && errno == EINTR { continue }
                throw HarnessError.failed("server read failed / client closed")
            }
        }
        return out
    }

    private func u16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
    private func u32(_ v: Int) -> [UInt8] {
        [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    }
    private func s32(_ v: Int32) -> [UInt8] { u32(Int(UInt32(bitPattern: v))) }

    // MARK: - Handshake

    private func handshake() throws {
        try send(Array("RFB 003.008\n".utf8))
        let clientVersion = try recv(12)
        guard String(bytes: clientVersion, encoding: .ascii)?.hasPrefix("RFB ") == true else {
            throw HarnessError.failed("client sent a bad version string")
        }

        try send([UInt8(offeredSecurity.count)] + offeredSecurity)
        let chosen = try recv(1)[0]
        guard offeredSecurity.contains(chosen) else {
            throw HarnessError.failed("client chose an unoffered security type \(chosen)")
        }
        if chosen == 2 {
            try send([UInt8](repeating: 0x5A, count: 16))   // challenge
            _ = try recv(16)                                 // response, unchecked
        }
        try send(u32(0))                                     // SecurityResult: OK

        _ = try recv(1)                                      // ClientInit (shared)

        var serverInit = u16(currentSize.0) + u16(currentSize.1)
        serverInit += PixelFormat.bgra.bytes
        let name = Array(desktopName.utf8)
        serverInit += u32(name.count) + name
        try send(serverInit)
    }

    // MARK: - Message loop

    private func serve() throws {
        while true {
            let type = try recv(1)[0]
            switch type {
            case 0:                                          // SetPixelFormat
                _ = try recv(3 + 16)
                lock.lock(); sawSetPixelFormat = true; lock.unlock()
            case 2:                                          // SetEncodings
                _ = try recv(1)
                let countBytes = try recv(2)
                let count = Int(countBytes[0]) << 8 | Int(countBytes[1])
                let body = try recv(count * 4)
                var encodings: [Int32] = []
                for i in 0..<count {
                    let base = i * 4
                    let raw = UInt32(body[base]) << 24 | UInt32(body[base + 1]) << 16
                            | UInt32(body[base + 2]) << 8 | UInt32(body[base + 3])
                    encodings.append(Int32(bitPattern: raw))
                }
                lock.lock(); sawEncodings = encodings; lock.unlock()
            case 3:                                          // FramebufferUpdateRequest
                let body = try recv(9)
                lock.lock()
                if body[0] != 0 && continuousUpdatesEnabled { sawIncrementalWhileContinuous = true }
                lock.unlock()
            case 4:                                          // KeyEvent
                let body = try recv(7)
                let down = body[0] != 0
                let keysym = UInt32(body[3]) << 24 | UInt32(body[4]) << 16
                           | UInt32(body[5]) << 8 | UInt32(body[6])
                lock.lock(); receivedKeys.append((keysym, down)); lock.unlock()
            case 5:                                          // PointerEvent
                let body = try recv(5)
                let x = Int(body[1]) << 8 | Int(body[2])
                let y = Int(body[3]) << 8 | Int(body[4])
                lock.lock(); receivedPointers.append((x, y, body[0])); lock.unlock()
            case 6:                                          // ClientCutText
                _ = try recv(3)
                let lengthBytes = try recv(4)
                let raw = Int32(bitPattern: UInt32(lengthBytes[0]) << 24 | UInt32(lengthBytes[1]) << 16
                                          | UInt32(lengthBytes[2]) << 8 | UInt32(lengthBytes[3]))
                if raw < 0 {
                    try handleExtClipboard(payloadLength: Int(-raw))
                } else {
                    _ = try recv(Int(raw))
                }
            case 150:                                        // EnableContinuousUpdates
                let body = try recv(9)
                let enable = body[0] != 0
                lock.lock(); continuousUpdatesEnabled = enable; lock.unlock()
                if !enable || endContinuousUpdatesOnEnable {
                    try send([150])                          // EndOfContinuousUpdates
                }
            case 248:                                        // ClientFence
                _ = try recv(3)
                _ = try recv(4)
                let length = Int(try recv(1)[0])
                _ = try recv(length)
            case 251:                                        // SetDesktopSize
                let head = try recv(7)
                let w = Int(head[1]) << 8 | Int(head[2])
                let h = Int(head[3]) << 8 | Int(head[4])
                let screens = Int(head[5])
                _ = try recv(screens * 16)
                lock.lock(); requestedSize = (w, h); lock.unlock()
                if resizeAnswersForwarded {
                    // neatvnc replies 4 with the OLD size, then follows up.
                    let old = currentSize
                    try sendExtendedDesktopSize(width: old.0, height: old.1,
                                                reason: 1, result: 4)
                    lock.lock(); currentSize = (w, h); lock.unlock()
                    try sendExtendedDesktopSize(width: w, height: h, reason: 0, result: 0)
                } else {
                    lock.lock(); currentSize = (w, h); lock.unlock()
                    try sendExtendedDesktopSize(width: w, height: h, reason: 1, result: 0)
                }
                onResize?(w, h)
            default:
                throw HarnessError.failed("server saw unknown client message \(type)")
            }
        }
    }

    /// Mirrors neatvnc's side of the notify/request/provide exchange.
    private func handleExtClipboard(payloadLength: Int) throws {
        let flagBytes = try recv(4)
        let flags = UInt32(flagBytes[0]) << 24 | UInt32(flagBytes[1]) << 16
                  | UInt32(flagBytes[2]) << 8 | UInt32(flagBytes[3])
        let body = payloadLength > 4 ? try recv(payloadLength - 4) : []

        let isCaps = flags & (1 << 24) != 0
        let isNotify = flags & (1 << 27) != 0
        let isProvide = flags & (1 << 28) != 0

        if isCaps { return }
        if isNotify {
            lock.lock(); sawClipboardNotify = true; lock.unlock()
            // Ask for it, exactly as neatvnc does.
            try sendExtClipboard(flags: (1 << 25) | 1, body: [])   // request | text
            return
        }
        if isProvide {
            if let text = try? ExtClipboardTestCodec.text(fromProvide: body) {
                lock.lock(); extClipboardText = text; lock.unlock()
            }
        }
    }

    func sendExtClipboard(flags: UInt32, body: [UInt8]) throws {
        var message: [UInt8] = [3, 0, 0, 0]
        let length = Int32(-(4 + body.count))
        let raw = UInt32(bitPattern: length)
        message += [UInt8(raw >> 24 & 0xff), UInt8(raw >> 16 & 0xff),
                    UInt8(raw >> 8 & 0xff), UInt8(raw & 0xff)]
        message += [UInt8(flags >> 24 & 0xff), UInt8(flags >> 16 & 0xff),
                    UInt8(flags >> 8 & 0xff), UInt8(flags & 0xff)]
        message += body
        try send(message)
    }

    /// caps | text | all actions, with max unsolicited size 0.
    func sendExtClipboardCaps() throws {
        let flags: UInt32 = (1 << 24) | 1 | (1 << 25) | (1 << 26) | (1 << 27) | (1 << 28)
        try sendExtClipboard(flags: flags, body: [0, 0, 0, 0])
    }

    func clipboardSeen() -> (text: String?, notified: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (extClipboardText, sawClipboardNotify)
    }

    // MARK: - Server-initiated frames

    /// Sends one rectangle using Tight BASIC with the copy filter.
    func sendTightFrame(rect: RFBRect, image: [[(UInt8, UInt8, UInt8)]], deflater: Deflater) throws {
        var message: [UInt8] = [0, 0] + u16(1)
        message += u16(rect.x) + u16(rect.y) + u16(rect.width) + u16(rect.height)
        message += s32(7)
        message += TightFixture.basicCopy(image: image, stream: 0, deflater: deflater, reset: true)
        try send(message)
    }

    /// Sends an arbitrary BGRA image as a Raw rectangle.
    func sendRawImage(rect: RFBRect, pixels: [UInt32]) throws {
        var message: [UInt8] = [0, 0] + u16(1)
        message += u16(rect.x) + u16(rect.y) + u16(rect.width) + u16(rect.height)
        message += s32(0)
        message.reserveCapacity(message.count + pixels.count * 4)
        for pixel in pixels {
            message += [UInt8(pixel & 0xff), UInt8((pixel >> 8) & 0xff),
                        UInt8((pixel >> 16) & 0xff), UInt8((pixel >> 24) & 0xff)]
        }
        try send(message)
    }

    func sendRawFrame(rect: RFBRect, colour: UInt32) throws {
        var message: [UInt8] = [0, 0] + u16(1)
        message += u16(rect.x) + u16(rect.y) + u16(rect.width) + u16(rect.height)
        message += s32(0)
        // Little-endian BGRA on the wire, matching the format we negotiated.
        let pixel: [UInt8] = [UInt8(colour & 0xff), UInt8((colour >> 8) & 0xff),
                              UInt8((colour >> 16) & 0xff), UInt8((colour >> 24) & 0xff)]
        for _ in 0..<(rect.width * rect.height) { message += pixel }
        try send(message)
    }

    func sendExtendedDesktopSize(width w: Int, height h: Int, reason: Int, result: Int) throws {
        var message: [UInt8] = [0, 0] + u16(1)
        message += u16(reason) + u16(result) + u16(w) + u16(h)
        message += s32(-308)
        message += [1, 0, 0, 0]                              // one screen
        message += u32(1) + u16(0) + u16(0) + u16(w) + u16(h) + u32(0)
        try send(message)
    }

    /// The zero-length support-confirmation rects neatvnc emits for the QEMU
    /// pseudo-encodings, plus a one-byte LED-state rect.
    func sendPseudoSupportRects() throws {
        var message: [UInt8] = [0, 0] + u16(3)
        message += u16(0) + u16(0) + u16(0) + u16(0) + s32(-258)   // qemu ext key
        message += u16(0) + u16(0) + u16(0) + u16(0) + s32(-316)   // ext mouse buttons
        message += u16(0) + u16(0) + u16(0) + u16(0) + s32(-261)   // led state
        message += [0x02]                                          // one payload byte
        try send(message)
    }

    /// Answers a resize the way neatvnc does: status 4 (REQUEST_FORWARDED)
    /// first, then the real size as a server-initiated rect.
    var resizeAnswersForwarded = false

    func sendServerCutText(_ text: String) throws {
        let bytes = Array(text.utf8)
        var message: [UInt8] = [3, 0, 0, 0]
        message += u32(bytes.count) + bytes
        try send(message)
    }

    /// A ServerCutText whose length field is set verbatim, without any payload
    /// following — used to exercise the client's bounds and overflow checks on
    /// a hostile length. `raw` is written as the big-endian u32 length.
    func sendServerCutTextRawLength(_ raw: UInt32) throws {
        var message: [UInt8] = [3, 0, 0, 0]
        message += u32(Int(raw))
        try send(message)
    }

    /// A framebuffer-update carrying a single DesktopSize pseudo-rect with the
    /// given (possibly hostile) dimensions and no pixel payload.
    func sendDesktopSizePseudoRect(width w: Int, height h: Int) throws {
        var message: [UInt8] = [0, 0]        // FramebufferUpdate, padding
        message += u16(1)                    // one rectangle
        message += u16(0) + u16(0) + u16(w) + u16(h)
        message += s32(-223)                 // DesktopSize pseudo-encoding
        try send(message)
    }

    func snapshot() -> (pixelFormat: Bool, encodings: [Int32], size: (Int, Int)?,
                        keys: [(UInt32, Bool)], pointers: [(Int, Int, UInt8)]) {
        lock.lock(); defer { lock.unlock() }
        return (sawSetPixelFormat, sawEncodings, requestedSize, receivedKeys, receivedPointers)
    }

    func sawBadIncremental() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return sawIncrementalWhileContinuous
    }

    func close() {
        if clientFD >= 0 { Foundation.close(clientFD); clientFD = -1 }
        if listenFD >= 0 { Foundation.close(listenFD); listenFD = -1 }
    }
}
