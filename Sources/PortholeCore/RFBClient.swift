import Foundation

public struct CursorImage {
    public var width: Int
    public var height: Int
    public var hotX: Int
    public var hotY: Int
    /// Premultiplied BGRA, alpha 0 where the server's mask is clear.
    public var pixels: [UInt32]
}

public struct SessionStats {
    public var bytesReceived: UInt64 = 0
    public var framesDecoded: UInt64 = 0
    public var lastFrameMilliseconds: Double = 0
    public var encodingName: String = "-"
}

public protocol RFBClientDelegate: AnyObject {
    func rfbDidConnect(_ client: RFBClient, width: Int, height: Int, desktopName: String)
    func rfbDidUpdateFramebuffer(_ client: RFBClient, dirty: [RFBRect])
    func rfbDidResize(_ client: RFBClient, width: Int, height: Int)
    func rfbDidReceiveCursor(_ client: RFBClient, cursor: CursorImage?)
    func rfbDidReceiveClipboard(_ client: RFBClient, text: String)
    func rfbDidRing(_ client: RFBClient)
    func rfbDidDisconnect(_ client: RFBClient, error: Error?)
    func rfbLog(_ client: RFBClient, message: String)
}

public struct RFBOptions {
    public var password: String?
    public var shared = true
    /// 0 (fastest, biggest) ... 9. Tight compression level pseudo-encoding.
    public var compressLevel: Int? = 6
    /// 0 (worst) ... 9 (best). nil requests lossless (no JPEG).
    public var jpegQuality: Int? = 8
    public var preferredEncodings: [Encoding] = [.tight, .zrle, .copyRect, .raw]
    /// Off by default. Continuous updates save a round trip per frame, but
    /// mixing them with an incremental request permanently wedges neatvnc's
    /// message parser (see `requestUpdate`), and the measured saving on a
    /// low-latency link does not justify the risk. Opt in with --continuous.
    public var useContinuousUpdates = false
    /// Advertise the Fence pseudo-encoding (server RTT/bandwidth probing).
    public var useFence = true
    public var trackRemoteCursor = true
    /// Use the extended clipboard, which carries UTF-8 instead of Latin-1.
    public var useExtendedClipboard = true
    public init() {}
}

public final class RFBClient {
    /// Hard ceilings on server-supplied sizes. Every length below is read
    /// straight off the wire, so without a cap a malicious or compromised
    /// server (or a MITM on a `--direct` link) can name a multi-gigabyte
    /// allocation in a handful of bytes and OOM the client. These bounds are
    /// generous enough that no legitimate frame is affected.
    static let maxDimension = 16384          // matches the --res clamp
    static let maxStringBytes = 1 << 20      // desktop name, reject/failure reasons
    static let maxCutTextBytes = 1 << 20     // legacy ServerCutText payload
    static let maxCursorDimension = 1024     // cursors are small; this is already huge

    public weak var delegate: RFBClientDelegate?
    /// Diagnostic hook for outbound input messages.
    public var traceInput: ((String) -> Void)?
    public let framebuffer: Framebuffer
    public private(set) var desktopName = ""
    public private(set) var stats = SessionStats()
    public private(set) var supportsResize = false

    private let transport: Transport
    private let reader: BufferedReader
    private let options: RFBOptions
    private var pixelFormat = PixelFormat.bgra
    private let tight = TightDecoder()
    private let zrle = ZRLEDecoder()
    private var thread: Thread?
    private var running = false
    /// True from the moment we ask the server for continuous updates until we
    /// have explicitly asked it to stop. Tracks what the *server* believes,
    /// not what it has told us — an EndOfContinuousUpdates message alone is
    /// not proof its flag is clear, and guessing wrong wedges its parser.
    private var continuousUpdatesActive = false
    private var sentContinuousUpdatesOff = false
    private let deflater = Deflater()
    /// Capability flags the server advertised; empty until its caps arrive.
    private var serverClipboardCaps = ExtClipboard.Flags(rawValue: 0)
    /// Text waiting to be handed over once the server asks for it.
    private var pendingClipboardText: String?
    private var lastUpdateAt = Date()
    private let stateLock = NSLock()

    public init(transport: Transport, options: RFBOptions) {
        self.transport = transport
        self.reader = BufferedReader(source: transport)
        self.options = options
        self.framebuffer = Framebuffer(width: 1, height: 1)
    }

    // MARK: - Handshake

    public func connect() throws {
        let banner = try reader.readBytes(12)
        guard let version = String(bytes: banner, encoding: .ascii), version.hasPrefix("RFB ") else {
            throw RFBError.handshake("bad server banner")
        }
        log("server speaks \(version.trimmingCharacters(in: .whitespacesAndNewlines))")
        // Every server we care about (neatvnc, TigerVNC, x11vnc) speaks 3.8.
        try transport.write(Array("RFB 003.008\n".utf8))

        try authenticate()

        try transport.write([options.shared ? 1 : 0])

        let width = Int(try reader.readU16())
        let height = Int(try reader.readU16())
        try Self.checkFramebufferSize(width: width, height: height)
        let serverFormat = try PixelFormat(reader: reader)
        let nameLength = try Self.checkLength(Int(try reader.readU32()),
                                              max: Self.maxStringBytes, what: "desktop name")
        let nameBytes = try reader.readBytes(nameLength)
        desktopName = String(bytes: nameBytes, encoding: .utf8) ?? "remote"
        log("desktop \"\(desktopName)\" \(width)x\(height), server format \(serverFormat.bitsPerPixel)bpp")

        framebuffer.resize(width: width, height: height)

        try setPixelFormat(.bgra)
        try setEncodings()

        // Like every other callback, this must reach the delegate on the main
        // queue: it runs on the connecting thread and delegates touch AppKit.
        let name = desktopName
        dispatch { self.delegate?.rfbDidConnect(self, width: width, height: height, desktopName: name) }
    }

    private func authenticate() throws {
        let count = Int(try reader.readU8())
        if count == 0 {
            let reasonLength = try Self.checkLength(Int(try reader.readU32()), max: Self.maxStringBytes, what: "reason")
            let reason = String(bytes: try reader.readBytes(reasonLength), encoding: .utf8) ?? "unknown"
            throw RFBError.handshake(reason)
        }
        let offered = try reader.readBytes(count)
        log("server offers auth: " + offered.map { SecurityType(rawValue: $0)?.label ?? "unknown(\($0))" }
            .joined(separator: ", "))

        // Prefer no-auth when the transport already authenticates us (SSH tunnel
        // to loopback, or a peer on a private encrypted network), otherwise
        // fall back to VNC auth.
        let chosen: SecurityType
        if offered.contains(SecurityType.none.rawValue) {
            chosen = .none
        } else if offered.contains(SecurityType.vncAuth.rawValue) {
            chosen = .vncAuth
        } else {
            throw RFBError.authUnsupported(offered)
        }
        log("using \(chosen.label)")
        try transport.write([chosen.rawValue])

        switch chosen {
        case .none:
            break
        case .vncAuth:
            guard let password = options.password, !password.isEmpty else {
                throw RFBError.passwordRequired
            }
            let challenge = try reader.readBytes(16)
            try transport.write(try VNCAuth.response(challenge: challenge, password: password))
        default:
            throw RFBError.authUnsupported(offered)
        }

        let result = try reader.readU32()
        if result != 0 {
            let reasonLength = try Self.checkLength(Int(try reader.readU32()), max: Self.maxStringBytes, what: "reason")
            let reason = String(bytes: try reader.readBytes(reasonLength), encoding: .utf8) ?? "rejected"
            throw RFBError.authFailed(reason)
        }
    }

    private func setPixelFormat(_ format: PixelFormat) throws {
        pixelFormat = format
        var msg = MessageBuilder(.setPixelFormat)
        msg.pad(3)
        msg.raw(format.bytes)
        try transport.write(msg.bytes)
    }

    private func setEncodings() throws {
        var list = options.preferredEncodings.map { $0.rawValue }
        list += [
            Encoding.pseudoExtendedDesktopSize.rawValue,
            Encoding.pseudoDesktopSize.rawValue,
            Encoding.pseudoDesktopName.rawValue,
            Encoding.pseudoLastRect.rawValue,
        ]
        if options.useFence { list.append(Encoding.pseudoFence.rawValue) }
        if options.useContinuousUpdates { list.append(Encoding.pseudoContinuousUpdates.rawValue) }
        // QEMU extended key events and extended mouse buttons are deliberately
        // not advertised: we send neither, and asking for them only makes the
        // server emit support-confirmation rects we would have to skip.
        if options.trackRemoteCursor { list.append(Encoding.pseudoCursor.rawValue) }
        if options.useExtendedClipboard { list.append(ExtClipboard.encoding) }
        if let level = options.compressLevel, (0...9).contains(level) {
            list.append(Encoding.pseudoCompressLevel0.rawValue + Int32(level))
        }
        if let quality = options.jpegQuality, (0...9).contains(quality) {
            list.append(Encoding.pseudoQualityLevel0.rawValue + Int32(quality))
        }

        var msg = MessageBuilder(.setEncodings)
        msg.pad(1)
        msg.u16(UInt16(list.count))
        for encoding in list { msg.s32(encoding) }
        try transport.write(msg.bytes)
    }

    // MARK: - Session loop

    public func start() {
        running = true
        let thread = Thread { [weak self] in self?.runLoop() }
        thread.name = "porthole.rfb"
        thread.stackSize = 1 << 20
        self.thread = thread
        thread.start()

        if options.useExtendedClipboard {
            // Advertise before anything else so the server knows it may use the
            // extended form for its own clipboard.
            try? writeClipboardMessage(ExtClipboard.capsBody(
                maxUnsolicitedText: UInt32(ExtClipboard.maxPayload)))
        }
        if options.useContinuousUpdates {
            try? setContinuousUpdates(true)
        }
        try? requestUpdate(incremental: false)
        startWatchdog()
    }

    public func stop() {
        running = false
        transport.close()
    }

    private func runLoop() {
        do {
            while running {
                let type = try reader.readU8()
                switch ServerMessage(rawValue: type) {
                case .framebufferUpdate:
                    try handleFramebufferUpdate()
                case .setColourMapEntries:
                    try reader.skip(3)
                    let count = Int(try reader.readU16())
                    try reader.skip(count * 6)
                case .bell:
                    dispatch { self.delegate?.rfbDidRing(self) }
                case .serverCutText:
                    try handleServerCutText()
                case .endOfContinuousUpdates:
                    // Turn it off explicitly rather than assuming the server's
                    // flag is clear, then fall back to request/response. The
                    // request is non-incremental because it is only safe to
                    // assume the flag is clear once we have said so ourselves.
                    log("server ended continuous updates; using request/response")
                    if continuousUpdatesActive && !sentContinuousUpdatesOff {
                        sentContinuousUpdatesOff = true
                        try setContinuousUpdates(false)
                    }
                    continuousUpdatesActive = false
                    try requestUpdate(incremental: false)
                case .serverFence:
                    try handleFence()
                case .none:
                    throw RFBError.protocolViolation("unknown server message \(type)")
                }
            }
            finish(error: nil)
        } catch {
            finish(error: running ? error : nil)
        }
    }

    private func finish(error: Error?) {
        guard running else { return }
        running = false
        transport.close()
        dispatch { self.delegate?.rfbDidDisconnect(self, error: error) }
    }

    private func handleFramebufferUpdate() throws {
        let began = Date()
        try reader.skip(1)
        let rectCount = Int(try reader.readU16())
        var dirty: [RFBRect] = []
        dirty.reserveCapacity(rectCount)
        var lastEncoding = stats.encodingName
        var resized: (Int, Int)?

        framebuffer.lock.lock()
        do {
            var index = 0
            while index < rectCount {
                index += 1
                let x = Int(try reader.readU16())
                let y = Int(try reader.readU16())
                let w = Int(try reader.readU16())
                let h = Int(try reader.readU16())
                let encoding = try reader.readS32()
                let rect = RFBRect(x: x, y: y, width: w, height: h)

                switch encoding {
                case Encoding.pseudoLastRect.rawValue:
                    index = rectCount

                case Encoding.pseudoDesktopSize.rawValue:
                    try resizeFramebuffer(width: w, height: h)
                    resized = (w, h)

                case Encoding.pseudoExtendedDesktopSize.rawValue:
                    let screens = Int(try reader.readU8())
                    try reader.skip(3)
                    try reader.skip(screens * 16)
                    supportsResize = true
                    // x is the reason, y the result code. Reason 1 means this
                    // rect answers our own request.
                    if x == 1 {
                        switch y {
                        case 0:
                            try resizeFramebuffer(width: w, height: h)
                            resized = (w, h)
                        case 4:
                            // REQUEST_FORWARDED: accepted and handed to the
                            // compositor. The size that actually took effect
                            // arrives later as a server-initiated rect, and
                            // w/h here are still the old ones — so do not
                            // resize, and do not treat this as a failure.
                            log("resize accepted; waiting for the compositor")
                        default:
                            log("server refused our resize request (\(Self.resizeStatus(y)))")
                        }
                    } else {
                        try resizeFramebuffer(width: w, height: h)
                        resized = (w, h)
                    }

                case Encoding.pseudoQemuExtendedKey.rawValue,
                     Encoding.pseudoExtendedMouseButtons.rawValue:
                    // Zero-length support confirmations. We do not use either,
                    // but a server may send them, and treating one as an error
                    // would drop the session.
                    break

                case Encoding.pseudoQemuLedState.rawValue:
                    try reader.skip(1)

                case Encoding.pseudoVMwareLedState.rawValue:
                    try reader.skip(4)

                case Encoding.pseudoDesktopName.rawValue:
                    let length = try Self.checkLength(Int(try reader.readU32()),
                                                      max: Self.maxStringBytes, what: "desktop name")
                    let bytes = try reader.readBytes(length)
                    desktopName = String(bytes: bytes, encoding: .utf8) ?? desktopName

                case Encoding.pseudoCursor.rawValue:
                    let cursor = try readCursor(rect: rect)
                    dispatch { self.delegate?.rfbDidReceiveCursor(self, cursor: cursor) }

                case Encoding.raw.rawValue:
                    try decodeRaw(rect: rect)
                    dirty.append(rect)
                    lastEncoding = "raw"

                case Encoding.copyRect.rawValue:
                    let sx = Int(try reader.readU16())
                    let sy = Int(try reader.readU16())
                    framebuffer.copy(from: RFBRect(x: sx, y: sy, width: w, height: h), toX: x, toY: y)
                    dirty.append(rect)
                    lastEncoding = "copyrect"

                case Encoding.tight.rawValue:
                    guard rect.width > 0, rect.height > 0 else { break }
                    try tight.decode(reader: reader, rect: clamp(rect), into: framebuffer, pixelFormat: pixelFormat)
                    dirty.append(rect)
                    lastEncoding = "tight"

                case Encoding.zrle.rawValue, Encoding.trle.rawValue:
                    try zrle.decode(reader: reader, rect: clamp(rect), into: framebuffer,
                                    pixelFormat: pixelFormat,
                                    compressed: encoding == Encoding.zrle.rawValue)
                    dirty.append(rect)
                    lastEncoding = encoding == Encoding.zrle.rawValue ? "zrle" : "trle"

                default:
                    throw RFBError.protocolViolation(
                        "server used encoding \(encoding), which was not negotiated; "
                        + "the stream cannot be resynchronised")
                }
            }
        } catch {
            framebuffer.lock.unlock()
            throw error
        }
        framebuffer.lock.unlock()

        stateLock.lock()
        stats.bytesReceived = reader.bytesRead
        stats.framesDecoded += 1
        stats.lastFrameMilliseconds = Date().timeIntervalSince(began) * 1000
        stats.encodingName = lastEncoding
        stateLock.unlock()
        lastUpdateAt = Date()

        if let (w, h) = resized {
            dispatch { self.delegate?.rfbDidResize(self, width: w, height: h) }
        }
        if !dirty.isEmpty {
            dispatch { self.delegate?.rfbDidUpdateFramebuffer(self, dirty: dirty) }
        }
        if !continuousUpdatesActive {
            try requestUpdate(incremental: true)
        }
    }

    /// Result codes from the ExtendedDesktopSize pseudo-encoding.
    private static func resizeStatus(_ code: Int) -> String {
        switch code {
        case 0: return "success"
        case 1: return "administratively prohibited"
        case 2: return "out of resources"
        case 3: return "invalid screen layout"
        case 4: return "request forwarded"
        default: return "code \(code)"
        }
    }

    private func clamp(_ rect: RFBRect) -> RFBRect {
        var r = rect
        r.width = min(r.width, max(0, framebuffer.width - r.x))
        r.height = min(r.height, max(0, framebuffer.height - r.y))
        return r
    }

    /// Rejects a server-named framebuffer size that is zero or larger than we
    /// will ever legitimately allocate, before it reaches `Framebuffer.resize`.
    private static func checkFramebufferSize(width: Int, height: Int) throws {
        guard width >= 1, height >= 1, width <= maxDimension, height <= maxDimension else {
            throw RFBError.protocolViolation("server framebuffer size \(width)x\(height) is out of range")
        }
    }

    /// Rejects an implausible wire length before it is handed to an allocation.
    private static func checkLength(_ length: Int, max: Int, what: String) throws -> Int {
        guard length >= 0, length <= max else {
            throw RFBError.protocolViolation("\(what) length \(length) is out of range")
        }
        return length
    }

    private func resizeFramebuffer(width w: Int, height h: Int) throws {
        try Self.checkFramebufferSize(width: w, height: h)
        framebuffer.resize(width: w, height: h)
    }

    private func decodeRaw(rect: RFBRect) throws {
        let clamped = clamp(rect)
        let bpp = pixelFormat.bytesPerPixel
        guard clamped.width > 0, clamped.height > 0 else {
            try reader.skip(rect.width * rect.height * bpp)
            return
        }
        // Negotiated format matches the framebuffer exactly, so rows land
        // straight in place with no per-pixel work.
        if bpp == 4 && !pixelFormat.bigEndian && pixelFormat == .bgra && clamped.width == rect.width {
            for y in 0..<clamped.height {
                try reader.readRaw(into: framebuffer.row(clamped.y + y) + clamped.x,
                                   count: clamped.width * 4)
            }
            return
        }
        var line = [UInt8](repeating: 0, count: rect.width * bpp)
        for y in 0..<rect.height {
            try line.withUnsafeMutableBytes { try reader.readRaw(into: $0.baseAddress!, count: rect.width * bpp) }
            guard clamped.y + y < framebuffer.height else { continue }
            let dst = framebuffer.row(clamped.y + y) + clamped.x
            line.withUnsafeBytes { src in
                let base = src.baseAddress!.assumingMemoryBound(to: UInt8.self)
                for x in 0..<clamped.width { dst[x] = decodePixel(base + x * bpp, bpp, pixelFormat) }
            }
        }
    }

    private func readCursor(rect: RFBRect) throws -> CursorImage? {
        // The cursor rect is not clamped to the framebuffer, so bound it here:
        // a 65535x65535 cursor would otherwise name a ~17 GB allocation.
        guard rect.width <= Self.maxCursorDimension, rect.height <= Self.maxCursorDimension else {
            throw RFBError.protocolViolation("cursor size \(rect.width)x\(rect.height) is out of range")
        }
        let bpp = pixelFormat.bytesPerPixel
        let pixelBytes = rect.width * rect.height * bpp
        let maskBytes = ((rect.width + 7) / 8) * rect.height
        let raw = try reader.readBytes(pixelBytes)
        let mask = try reader.readBytes(maskBytes)
        guard rect.width > 0, rect.height > 0 else { return nil }

        var pixels = [UInt32](repeating: 0, count: rect.width * rect.height)
        raw.withUnsafeBytes { src in
            let base = src.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let maskStride = (rect.width + 7) / 8
            for y in 0..<rect.height {
                for x in 0..<rect.width {
                    let visible = (mask[y * maskStride + x / 8] >> (7 - UInt8(x % 8))) & 1
                    if visible == 1 {
                        pixels[y * rect.width + x] = decodePixel(base + (y * rect.width + x) * bpp, bpp, pixelFormat)
                    }
                }
            }
        }
        return CursorImage(width: rect.width, height: rect.height,
                           hotX: rect.x, hotY: rect.y, pixels: pixels)
    }

    private func handleServerCutText() throws {
        try reader.skip(3)
        let length = Int32(bitPattern: try reader.readU32())
        if length < 0 {
            // Negate in a wider type: `-Int32.min` overflows and traps, so a
            // server sending a length field of 0x80000000 would crash us here.
            try handleExtendedClipboard(payloadLength: Int(-Int64(length)))
            return
        }
        guard length > 0 else { return }
        let count = try Self.checkLength(Int(length), max: Self.maxCutTextBytes, what: "cut text")
        let bytes = try reader.readBytes(count)
        // Latin-1 by specification, but most servers — wayvnc included — put
        // UTF-8 in here anyway, and decoding that as Latin-1 yields mojibake.
        // Prefer UTF-8 when the bytes form a valid sequence.
        let text = String(bytes: bytes, encoding: .utf8)
            ?? String(bytes.map { Character(UnicodeScalar($0)) })
        dispatch { self.delegate?.rfbDidReceiveClipboard(self, text: text) }
    }

    /// The extended clipboard exchange. `payloadLength` counts the flags word
    /// plus whatever follows it.
    private func handleExtendedClipboard(payloadLength: Int) throws {
        guard payloadLength >= 4, payloadLength <= ExtClipboard.maxPayload else {
            try reader.skip(max(0, payloadLength))
            return
        }
        let flags = ExtClipboard.Flags(rawValue: try reader.readU32())
        let bodyLength = payloadLength - 4
        let body = bodyLength > 0 ? try reader.readBytes(bodyLength) : []
        log("clipboard message: \(ExtClipboard.describe(flags)) (\(bodyLength) bytes)")

        if flags.contains(.caps) {
            serverClipboardCaps = flags
            log("extended clipboard enabled")
            // If a copy happened before caps arrived, announce it now.
            if pendingClipboardText != nil { try? announceClipboard() }
            return
        }
        if flags.contains(.provide) && flags.contains(.text) {
            do {
                if let text = try ExtClipboard.textFromProvide(body), !text.isEmpty {
                    dispatch { self.delegate?.rfbDidReceiveClipboard(self, text: text) }
                } else {
                    log("clipboard provide was empty")
                }
            } catch {
                log("clipboard provide could not be decoded: \(error)")
            }
            return
        }
        if flags.contains(.notify) && flags.contains(.text) {
            // The server has something; ask for it.
            try? writeClipboardMessage(ExtClipboard.actionBody([.request, .text]))
            return
        }
        if flags.contains(.request) && flags.contains(.text) {
            try? sendPendingClipboard()
            return
        }
        if flags.contains(.peek) {
            try? announceClipboard()
        }
    }

    /// ClientCutText carrying an extended-clipboard body: the length field is
    /// the negated body size.
    private func writeClipboardMessage(_ body: [UInt8]) throws {
        var msg = MessageBuilder(.clientCutText)
        msg.pad(3)
        msg.u32(UInt32(bitPattern: Int32(-body.count)))
        msg.raw(body)
        try transport.write(msg.bytes)
    }

    private func announceClipboard() throws {
        guard pendingClipboardText != nil else { return }
        try writeClipboardMessage(ExtClipboard.actionBody([.notify, .text]))
    }

    private func sendPendingClipboard() throws {
        guard let text = pendingClipboardText else { return }
        let body = try ExtClipboard.provideBody(text: text, deflater: deflater)
        guard body.count <= ExtClipboard.maxPayload else {
            log("clipboard too large to send (\(body.count) bytes)")
            return
        }
        try writeClipboardMessage(body)
    }

    /// True once the server has told us it speaks the extended clipboard.
    public var extendedClipboardActive: Bool {
        serverClipboardCaps.contains(.caps)
    }

    /// Fences are the server's flow-control barrier; failing to echo one stalls
    /// the stream permanently.
    private func handleFence() throws {
        try reader.skip(3)
        let flags = try reader.readU32()
        let length = Int(try reader.readU8())
        let payload = try reader.readBytes(length)
        guard flags & 0x8000_0000 != 0 else { return }
        var msg = MessageBuilder(.clientFence)
        msg.pad(3)
        msg.u32(flags & ~0x8000_0000)
        msg.u8(UInt8(length))
        msg.raw(payload)
        try transport.write(msg.bytes)
    }

    // MARK: - Client to server

    public func requestUpdate(incremental: Bool) throws {
        // neatvnc's on_client_fb_update_request returns 0 — its "message
        // incomplete, retry later" signal — for an incremental request while
        // continuous updates are enabled. That stalls its parser forever: the
        // screen keeps updating, because that side is server-driven, but no
        // further client message is ever read, so keyboard and mouse die
        // silently. Never send the combination.
        if incremental && continuousUpdatesActive { return }
        var msg = MessageBuilder(.framebufferUpdateRequest)
        msg.u8(incremental ? 1 : 0)
        msg.u16(0); msg.u16(0)
        msg.u16(UInt16(clamping: framebuffer.width))
        msg.u16(UInt16(clamping: framebuffer.height))
        try transport.write(msg.bytes)
    }

    /// Lets the server push frames as they change instead of waiting a round
    /// trip for each request — worth a frame of latency on a WAN link.
    private func setContinuousUpdates(_ enabled: Bool) throws {
        var msg = MessageBuilder(.enableContinuousUpdates)
        msg.u8(enabled ? 1 : 0)
        msg.u16(0); msg.u16(0)
        msg.u16(UInt16(clamping: framebuffer.width))
        msg.u16(UInt16(clamping: framebuffer.height))
        try transport.write(msg.bytes)
        continuousUpdatesActive = enabled
    }

    /// Re-arms the request loop if the stream goes quiet, so a server that
    /// silently ignored EnableContinuousUpdates cannot wedge the session.
    private func startWatchdog() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.running else { return }
            if Date().timeIntervalSince(self.lastUpdateAt) > 1.0 {
                if self.continuousUpdatesActive {
                    // Turn it off at the server too, so its own flag clears;
                    // otherwise our later incremental requests would stall it.
                    self.log("no frames under continuous updates; reverting to request/response")
                    try? self.setContinuousUpdates(false)
                }
                // Always non-incremental here: safe even if the server enabled
                // continuous updates without us knowing.
                try? self.requestUpdate(incremental: false)
            }
            self.startWatchdog()
        }
    }

    public func sendKey(keysym: UInt32, down: Bool) {
        var msg = MessageBuilder(.keyEvent)
        msg.u8(down ? 1 : 0)
        msg.pad(2)
        msg.u32(keysym)
        writeInput(msg.bytes, label: "key \(down ? "down" : "up") 0x\(String(keysym, radix: 16))")
    }

    /// Input writes are fire-and-forget, but a silently swallowed error here
    /// looks exactly like "the remote ignores my keyboard", so surface it.
    private func writeInput(_ bytes: [UInt8], label: String) {
        do {
            try transport.write(bytes)
            traceInput?("\(label) -> " + bytes.map { String(format: "%02x", $0) }.joined(separator: " "))
        } catch {
            traceInput?("\(label) FAILED: \(error)")
        }
    }

    public func sendPointer(x: Int, y: Int, buttonMask: UInt8) {
        var msg = MessageBuilder(.pointerEvent)
        msg.u8(buttonMask)
        msg.u16(UInt16(clamping: max(0, x)))
        msg.u16(UInt16(clamping: max(0, y)))
        writeInput(msg.bytes, label: "pointer \(x),\(y) mask \(buttonMask)")
    }

    public func sendClipboard(_ text: String) {
        pendingClipboardText = text
        if extendedClipboardActive {
            // Announce and wait to be asked: neatvnc advertises a maximum
            // unsolicited size of zero, so pushing the content directly would
            // be discarded.
            try? announceClipboard()
            return
        }
        // Legacy fallback. Latin-1 only, so anything else degrades to '?'.
        let latin1 = text.unicodeScalars.map { $0.value < 256 ? UInt8($0.value) : UInt8(63) }
        var msg = MessageBuilder(.clientCutText)
        msg.pad(3)
        msg.u32(UInt32(latin1.count))
        msg.raw(latin1)
        try? transport.write(msg.bytes)
    }

    /// Asks the compositor to reshape its output to match our window. wayvnc
    /// turns this into a `wlr_output_manager` resize of the headless output.
    public func requestDesktopSize(width: Int, height: Int) {
        let w = UInt16(clamping: max(1, width)), h = UInt16(clamping: max(1, height))
        var msg = MessageBuilder(.setDesktopSize)
        msg.pad(1)
        msg.u16(w); msg.u16(h)
        msg.u8(1)   // one screen
        msg.pad(1)
        msg.u32(1)  // screen id
        msg.u16(0); msg.u16(0)
        msg.u16(w); msg.u16(h)
        msg.u32(0)  // flags
        try? transport.write(msg.bytes)
        log("requested remote resolution \(width)x\(height)")
    }

    public func currentStats() -> SessionStats {
        stateLock.lock(); defer { stateLock.unlock() }
        return stats
    }

    private func dispatch(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }

    private func log(_ message: String) {
        dispatch { self.delegate?.rfbLog(self, message: message) }
    }
}
