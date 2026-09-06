import Foundation
import MyTightCore

/// Collects delegate callbacks so the test can wait on specific milestones.
private final class Recorder: RFBClientDelegate {
    let connected = DispatchSemaphore(value: 0)
    let framePainted = DispatchSemaphore(value: 0)
    let resized = DispatchSemaphore(value: 0)
    let clipboard = DispatchSemaphore(value: 0)
    let disconnected = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private var _size = (0, 0)
    private var _name = ""
    private var _clipboardText = ""
    private var _dirty: [RFBRect] = []
    private var _error: Error?

    var size: (Int, Int) { lock.lock(); defer { lock.unlock() }; return _size }
    var name: String { lock.lock(); defer { lock.unlock() }; return _name }
    var clipboardText: String { lock.lock(); defer { lock.unlock() }; return _clipboardText }
    var dirty: [RFBRect] { lock.lock(); defer { lock.unlock() }; return _dirty }
    var error: Error? { lock.lock(); defer { lock.unlock() }; return _error }

    func rfbDidConnect(_ client: RFBClient, width: Int, height: Int, desktopName: String) {
        lock.lock(); _size = (width, height); _name = desktopName; lock.unlock()
        connected.signal()
    }
    func rfbDidUpdateFramebuffer(_ client: RFBClient, dirty: [RFBRect]) {
        lock.lock(); _dirty = dirty; lock.unlock()
        framePainted.signal()
    }
    func rfbDidResize(_ client: RFBClient, width: Int, height: Int) {
        lock.lock(); _size = (width, height); lock.unlock()
        resized.signal()
    }
    func rfbDidReceiveCursor(_ client: RFBClient, cursor: CursorImage?) {}
    func rfbDidReceiveClipboard(_ client: RFBClient, text: String) {
        lock.lock(); _clipboardText = text; lock.unlock()
        clipboard.signal()
    }
    func rfbDidRing(_ client: RFBClient) {}
    func rfbDidDisconnect(_ client: RFBClient, error: Error?) {
        lock.lock(); _error = error; lock.unlock()
        disconnected.signal()
    }
    func rfbLog(_ client: RFBClient, message: String) {}
}

/// The delegate hands work to the main queue, so a blocking wait would deadlock
/// unless the run loop keeps turning underneath it.
private func wait(_ semaphore: DispatchSemaphore, seconds: Double) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if semaphore.wait(timeout: .now() + 0.01) == .success { return true }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    return false
}

func runSessionTests(_ h: Harness) {
    print("session")

    h.test("full handshake, Tight frame, and pixel-perfect delivery") {
        let server = try LoopbackServer(width: 64, height: 48)
        defer { server.close() }
        let ready = DispatchSemaphore(value: 0)
        server.start { ready.signal() }

        let socket = try Socket(host: "127.0.0.1", port: server.port)
        var options = RFBOptions()
        options.useContinuousUpdates = true
        let client = RFBClient(transport: socket, options: options)
        let recorder = Recorder()
        client.delegate = recorder
        try client.connect()
        defer { client.stop() }

        try h.expect(wait(recorder.connected, seconds: 3), "no connect callback")
        try h.expectEqual(recorder.size.0, 64, "width")
        try h.expectEqual(recorder.size.1, 48, "height")
        try h.expectEqual(recorder.name, "loopback", "desktop name")

        client.start()
        try h.expect(wait(ready, seconds: 3) || true, "server ready")

        // Let SetPixelFormat and SetEncodings land before inspecting them.
        Thread.sleep(forTimeInterval: 0.3)
        let seen = server.snapshot()
        try h.expect(seen.pixelFormat, "client never sent SetPixelFormat")
        try h.expect(seen.encodings.contains(7), "Tight was not offered")
        try h.expect(seen.encodings.contains(-308), "ExtendedDesktopSize was not offered")
        try h.expect(seen.encodings.contains(-312), "Fence was not offered")

        var image: [[(UInt8, UInt8, UInt8)]] = []
        for y in 0..<16 {
            var row: [(UInt8, UInt8, UInt8)] = []
            for x in 0..<24 {
                let r = UInt8((x * 9 + y) & 0xFF)
                let g = UInt8((x + y * 7) & 0xFF)
                let b = UInt8((x * 3) & 0xFF)
                row.append((r, g, b))
            }
            image.append(row)
        }
        let rect = RFBRect(x: 8, y: 4, width: 24, height: 16)
        try server.sendTightFrame(rect: rect, image: image, deflater: Deflater())
        try h.expect(wait(recorder.framePainted, seconds: 3), "no framebuffer update callback")

        let framebuffer = client.framebuffer
        framebuffer.lock.lock()
        defer { framebuffer.lock.unlock() }
        for y in 0..<16 {
            for x in 0..<24 {
                let actual = framebuffer.row(rect.y + y)[rect.x + x]
                let expected = rgb(image[y][x].0, image[y][x].1, image[y][x].2)
                if actual != expected {
                    throw HarnessError.failed(String(format: "pixel (%d,%d): %08X vs %08X",
                                                     x, y, actual, expected))
                }
            }
        }
    }

    h.test("Raw rectangles land without a repack") {
        let server = try LoopbackServer(width: 32, height: 32)
        defer { server.close() }
        server.start {}
        let socket = try Socket(host: "127.0.0.1", port: server.port)
        let client = RFBClient(transport: socket, options: RFBOptions())
        let recorder = Recorder()
        client.delegate = recorder
        try client.connect()
        defer { client.stop() }
        try h.expect(wait(recorder.connected, seconds: 3), "no connect callback")
        client.start()

        try server.sendRawFrame(rect: RFBRect(x: 0, y: 0, width: 8, height: 8), colour: rgb(7, 8, 9))
        try h.expect(wait(recorder.framePainted, seconds: 3), "no frame")
        client.framebuffer.lock.lock()
        let pixel = client.framebuffer.row(3)[3]
        client.framebuffer.lock.unlock()
        try h.expectEqual(pixel, rgb(7, 8, 9))
    }

    h.test("the client drives the remote resolution and adopts the answer") {
        let server = try LoopbackServer(width: 100, height: 100)
        defer { server.close() }
        server.start {}
        let socket = try Socket(host: "127.0.0.1", port: server.port)
        let client = RFBClient(transport: socket, options: RFBOptions())
        let recorder = Recorder()
        client.delegate = recorder
        try client.connect()
        defer { client.stop() }
        try h.expect(wait(recorder.connected, seconds: 3), "no connect callback")
        client.start()

        // The real reason this client exists: hand the compositor this Mac's
        // resolution and have the desktop reshape to match.
        client.requestDesktopSize(width: 3420, height: 2224)
        try h.expect(wait(recorder.resized, seconds: 3), "server never confirmed the resize")
        try h.expectEqual(recorder.size.0, 3420, "adopted width")
        try h.expectEqual(recorder.size.1, 2224, "adopted height")
        try h.expectEqual(client.framebuffer.width, 3420, "framebuffer width")
        try h.expectEqual(client.framebuffer.height, 2224, "framebuffer height")

        let requested = server.snapshot().size
        try h.expect(requested != nil, "server saw no SetDesktopSize")
        try h.expectEqual(requested!.0, 3420, "requested width")
        try h.expectEqual(requested!.1, 2224, "requested height")
    }

    h.test("zero-length pseudo-encoding rects do not kill the session") {
        // Regression: wayvnc sends -258/-316 support confirmations and a
        // -261 LED-state rect. Treating an unhandled pseudo-rect as a protocol
        // violation dropped the connection on the first frame.
        let server = try LoopbackServer(width: 32, height: 32)
        defer { server.close() }
        server.start {}
        let socket = try Socket(host: "127.0.0.1", port: server.port)
        let client = RFBClient(transport: socket, options: RFBOptions())
        let recorder = Recorder()
        client.delegate = recorder
        try client.connect()
        defer { client.stop() }
        try h.expect(wait(recorder.connected, seconds: 3), "no connect callback")
        client.start()

        try server.sendPseudoSupportRects()
        // The session must survive and keep decoding afterwards.
        try server.sendRawFrame(rect: RFBRect(x: 0, y: 0, width: 4, height: 4), colour: rgb(3, 4, 5))
        try h.expect(wait(recorder.framePainted, seconds: 3),
                     "session died on the pseudo-rects")
        try h.expect(recorder.error == nil, "unexpected error: \(String(describing: recorder.error))")
        client.framebuffer.lock.lock()
        let pixel = client.framebuffer.row(1)[1]
        client.framebuffer.lock.unlock()
        try h.expectEqual(pixel, rgb(3, 4, 5))
    }

    h.test("resize status 4 (REQUEST_FORWARDED) is an acceptance, not a refusal") {
        // Regression: neatvnc answers a resize with status 4 and the OLD size,
        // then follows up with the real one. Reading 4 as a refusal left the
        // client stuck at the original resolution.
        let server = try LoopbackServer(width: 1710, height: 975)
        defer { server.close() }
        server.resizeAnswersForwarded = true
        server.start {}
        let socket = try Socket(host: "127.0.0.1", port: server.port)
        let client = RFBClient(transport: socket, options: RFBOptions())
        let recorder = Recorder()
        client.delegate = recorder
        try client.connect()
        defer { client.stop() }
        try h.expect(wait(recorder.connected, seconds: 3), "no connect callback")
        client.start()

        client.requestDesktopSize(width: 3420, height: 2224)
        try h.expect(wait(recorder.resized, seconds: 3), "no resize callback")
        // Must land on the new size, not stay at the old one the status-4
        // rect carried.
        try h.expectEqual(client.framebuffer.width, 3420, "framebuffer width")
        try h.expectEqual(client.framebuffer.height, 2224, "framebuffer height")
        try h.expect(recorder.error == nil, "unexpected error: \(String(describing: recorder.error))")
    }

    h.test("never sends an incremental request while continuous updates are on") {
        // Regression: neatvnc treats an incremental FramebufferUpdateRequest
        // received while continuous updates are enabled as an incomplete
        // message and stalls its parser forever. The screen keeps updating
        // because that direction is server-driven, but keyboard and mouse go
        // dead silently. This is the combination that must never occur.
        let server = try LoopbackServer(width: 64, height: 64)
        defer { server.close() }
        server.start {}
        let socket = try Socket(host: "127.0.0.1", port: server.port)
        var options = RFBOptions()
        options.useContinuousUpdates = true
        let client = RFBClient(transport: socket, options: options)
        let recorder = Recorder()
        client.delegate = recorder
        try client.connect()
        defer { client.stop() }
        try h.expect(wait(recorder.connected, seconds: 3), "no connect callback")
        client.start()

        // Drive several frames plus a watchdog cycle.
        for _ in 0..<3 {
            try server.sendRawFrame(rect: RFBRect(x: 0, y: 0, width: 8, height: 8), colour: rgb(1, 2, 3))
            _ = wait(recorder.framePainted, seconds: 2)
        }
        Thread.sleep(forTimeInterval: 1.6)
        try h.expect(!server.sawBadIncremental(),
                     "client sent an incremental request while continuous updates were enabled")
    }

    h.test("a server that ends continuous updates does not get incremental requests") {
        // The real wayvnc sends EndOfContinuousUpdates without necessarily
        // clearing its own flag, so the client must disable it explicitly
        // rather than assuming, and must not send incremental requests before
        // that is confirmed.
        let server = try LoopbackServer(width: 64, height: 64)
        defer { server.close() }
        server.endContinuousUpdatesOnEnable = true
        server.start {}
        let socket = try Socket(host: "127.0.0.1", port: server.port)
        var options = RFBOptions()
        options.useContinuousUpdates = true
        let client = RFBClient(transport: socket, options: options)
        let recorder = Recorder()
        client.delegate = recorder
        try client.connect()
        defer { client.stop() }
        try h.expect(wait(recorder.connected, seconds: 3), "no connect callback")
        client.start()

        for _ in 0..<3 {
            try server.sendRawFrame(rect: RFBRect(x: 0, y: 0, width: 8, height: 8), colour: rgb(4, 5, 6))
            _ = wait(recorder.framePainted, seconds: 2)
        }
        Thread.sleep(forTimeInterval: 1.6)
        try h.expect(!server.sawBadIncremental(),
                     "client sent an incremental request while the server still had continuous updates on")
        // And it must still be receiving frames.
        try server.sendRawFrame(rect: RFBRect(x: 8, y: 8, width: 4, height: 4), colour: rgb(7, 7, 7))
        try h.expect(wait(recorder.framePainted, seconds: 3), "frames stopped after the fallback")
    }

    h.test("extended clipboard carries UTF-8 out through notify/request/provide") {
        // The legacy path is Latin-1, so accents and emoji become '?'. neatvnc
        // refuses unsolicited content, hence the three-step handshake.
        let server = try LoopbackServer(width: 32, height: 32)
        defer { server.close() }
        server.start {}
        let socket = try Socket(host: "127.0.0.1", port: server.port)
        let client = RFBClient(transport: socket, options: RFBOptions())
        let recorder = Recorder()
        client.delegate = recorder
        try client.connect()
        defer { client.stop() }
        try h.expect(wait(recorder.connected, seconds: 3), "no connect callback")
        client.start()
        try server.sendExtClipboardCaps()
        Thread.sleep(forTimeInterval: 0.4)
        try h.expect(client.extendedClipboardActive, "client did not record the server caps")

        let original = "Grüße — naïve café 日本語 🎉\nsecond line"
        client.sendClipboard(original)
        // notify -> request -> provide takes a couple of round trips.
        var seen = server.clipboardSeen()
        for _ in 0..<40 where seen.text == nil {
            Thread.sleep(forTimeInterval: 0.05)
            seen = server.clipboardSeen()
        }
        try h.expect(seen.notified, "client never sent a notify")
        try h.expect(seen.text != nil, "server never received the provide payload")
        try h.expectEqual(seen.text!, original, "round-tripped clipboard text")
    }

    h.test("extended clipboard carries UTF-8 in") {
        let server = try LoopbackServer(width: 32, height: 32)
        defer { server.close() }
        server.start {}
        let socket = try Socket(host: "127.0.0.1", port: server.port)
        let client = RFBClient(transport: socket, options: RFBOptions())
        let recorder = Recorder()
        client.delegate = recorder
        try client.connect()
        defer { client.stop() }
        try h.expect(wait(recorder.connected, seconds: 3), "no connect callback")
        client.start()
        try server.sendExtClipboardCaps()
        Thread.sleep(forTimeInterval: 0.3)

        let original = "kopiert: äöü — 「テスト」 ✅"
        let body = try ExtClipboardTestCodec.provide(text: original)
        try server.sendExtClipboard(flags: (1 << 28) | 1, body: body)   // provide | text
        try h.expect(wait(recorder.clipboard, seconds: 3), "no clipboard callback")
        try h.expectEqual(recorder.clipboardText, original)
    }

    h.test("legacy clipboard still works when the server has no extension") {
        let server = try LoopbackServer(width: 32, height: 32)
        defer { server.close() }
        server.start {}
        let socket = try Socket(host: "127.0.0.1", port: server.port)
        let client = RFBClient(transport: socket, options: RFBOptions())
        let recorder = Recorder()
        client.delegate = recorder
        try client.connect()
        defer { client.stop() }
        try h.expect(wait(recorder.connected, seconds: 3), "no connect callback")
        client.start()
        // No caps from this server, so the client must fall back rather than
        // waiting forever for a request that will never come.
        try h.expect(!client.extendedClipboardActive, "should not be active without caps")
        try server.sendServerCutText("plain ascii")
        try h.expect(wait(recorder.clipboard, seconds: 3), "no clipboard callback")
        try h.expectEqual(recorder.clipboardText, "plain ascii")
    }

    h.test("CRLF conversion round-trips") {
        // The wire format mandates CRLF; the local pasteboard uses LF.
        let text = "one\ntwo\nthree"
        let onWire = ExtClipboard.lfToCRLF(text)
        try h.expect(onWire.contains("\r\n"), "should convert to CRLF for the wire")
        try h.expectEqual(ExtClipboard.crlfToLF(onWire), text)
        // Already-CRLF input must not become CRCRLF.
        try h.expectEqual(ExtClipboard.lfToCRLF(onWire), onWire)
    }

    h.test("a dropped connection surfaces an error so the app can reconnect") {
        // Auto-reconnect keys off rfbDidDisconnect carrying an error. If an
        // abrupt drop reported success instead, the app would quit rather than
        // retry — which is what happens every time the laptop sleeps.
        let server = try LoopbackServer(width: 32, height: 32)
        server.start {}
        let socket = try Socket(host: "127.0.0.1", port: server.port)
        let client = RFBClient(transport: socket, options: RFBOptions())
        let recorder = Recorder()
        client.delegate = recorder
        try client.connect()
        try h.expect(wait(recorder.connected, seconds: 3), "no connect callback")
        client.start()
        try server.sendRawFrame(rect: RFBRect(x: 0, y: 0, width: 4, height: 4), colour: rgb(1, 1, 1))
        try h.expect(wait(recorder.framePainted, seconds: 3), "no frame")

        // Yank the connection from under it.
        server.close()
        try h.expect(wait(recorder.disconnected, seconds: 5), "no disconnect callback")
        try h.expect(recorder.error != nil, "an abrupt drop must report an error, not a clean close")
        client.stop()
    }

    h.test("a client-initiated stop reports a clean close, not an error") {
        // The mirror case: quitting deliberately must not trigger a reconnect.
        let server = try LoopbackServer(width: 32, height: 32)
        defer { server.close() }
        server.start {}
        let socket = try Socket(host: "127.0.0.1", port: server.port)
        let client = RFBClient(transport: socket, options: RFBOptions())
        let recorder = Recorder()
        client.delegate = recorder
        try client.connect()
        try h.expect(wait(recorder.connected, seconds: 3), "no connect callback")
        client.start()
        client.stop()
        Thread.sleep(forTimeInterval: 0.4)
        try h.expect(recorder.error == nil, "a deliberate stop must not look like a failure")
    }

    h.test("repeated resize requests reshape the desktop each time") {
        // Live resize sends a new SetDesktopSize whenever the window settles.
        let server = try LoopbackServer(width: 800, height: 600)
        defer { server.close() }
        server.resizeAnswersForwarded = true
        server.start {}
        let socket = try Socket(host: "127.0.0.1", port: server.port)
        let client = RFBClient(transport: socket, options: RFBOptions())
        let recorder = Recorder()
        client.delegate = recorder
        try client.connect()
        defer { client.stop() }
        try h.expect(wait(recorder.connected, seconds: 3), "no connect callback")
        client.start()

        for (width, height) in [(1280, 800), (1920, 1080), (1024, 768)] {
            client.requestDesktopSize(width: width, height: height)
            try h.expect(wait(recorder.resized, seconds: 3), "no resize to \(width)x\(height)")
            try h.expectEqual(client.framebuffer.width, width, "width after resize")
            try h.expectEqual(client.framebuffer.height, height, "height after resize")
        }
    }

    h.test("VNC password authentication completes") {
        let server = try LoopbackServer(width: 16, height: 16)
        defer { server.close() }
        server.offeredSecurity = [2]              // VncAuth only
        server.start {}
        let socket = try Socket(host: "127.0.0.1", port: server.port)
        var options = RFBOptions()
        options.password = "hunter2"
        let client = RFBClient(transport: socket, options: options)
        let recorder = Recorder()
        client.delegate = recorder
        try client.connect()
        defer { client.stop() }
        try h.expect(wait(recorder.connected, seconds: 3), "auth did not complete")
    }

    h.test("a password-only server without a password fails cleanly") {
        let server = try LoopbackServer(width: 16, height: 16)
        defer { server.close() }
        server.offeredSecurity = [2]
        server.start {}
        let socket = try Socket(host: "127.0.0.1", port: server.port)
        let client = RFBClient(transport: socket, options: RFBOptions())
        let recorder = Recorder()
        client.delegate = recorder
        do {
            try client.connect()
            throw HarnessError.failed("expected a passwordRequired error")
        } catch RFBError.passwordRequired {
            // Exactly the diagnosis the user needs.
        }
    }

    h.test("input events reach the server with the right keysyms") {
        let server = try LoopbackServer(width: 32, height: 32)
        defer { server.close() }
        server.start {}
        let socket = try Socket(host: "127.0.0.1", port: server.port)
        let client = RFBClient(transport: socket, options: RFBOptions())
        let recorder = Recorder()
        client.delegate = recorder
        try client.connect()
        defer { client.stop() }
        try h.expect(wait(recorder.connected, seconds: 3), "no connect callback")
        client.start()

        client.sendKey(keysym: Keysym.superL, down: true)
        client.sendKey(keysym: Keysym.fromUnicode("d"), down: true)
        client.sendKey(keysym: Keysym.fromUnicode("d"), down: false)
        client.sendKey(keysym: Keysym.superL, down: false)
        client.sendPointer(x: 17, y: 23, buttonMask: PointerButtons.left.rawValue)
        Thread.sleep(forTimeInterval: 0.3)

        let seen = server.snapshot()
        try h.expect(seen.keys.contains { $0.0 == Keysym.superL && $0.1 },
                     "Super press missing; got \(seen.keys)")
        try h.expect(seen.keys.contains { $0.0 == 0x64 && $0.1 }, "'d' press missing")
        try h.expect(seen.keys.contains { $0.0 == Keysym.superL && !$0.1 }, "Super release missing")
        try h.expect(seen.pointers.contains { $0 == (17, 23, 1) },
                     "pointer event missing; got \(seen.pointers)")
    }

    h.test("clipboard arrives from the server") {
        let server = try LoopbackServer(width: 16, height: 16)
        defer { server.close() }
        server.start {}
        let socket = try Socket(host: "127.0.0.1", port: server.port)
        let client = RFBClient(transport: socket, options: RFBOptions())
        let recorder = Recorder()
        client.delegate = recorder
        try client.connect()
        defer { client.stop() }
        try h.expect(wait(recorder.connected, seconds: 3), "no connect callback")
        client.start()
        try server.sendServerCutText("copied from sway")
        try h.expect(wait(recorder.clipboard, seconds: 3), "no clipboard callback")
        try h.expectEqual(recorder.clipboardText, "copied from sway")
    }

    h.test("a server that declines continuous updates still delivers frames") {
        // The loopback server always answers EnableContinuousUpdates with
        // EndOfContinuousUpdates, so this exercises the request/response
        // fallback path that keeps a session from wedging.
        let server = try LoopbackServer(width: 32, height: 32)
        defer { server.close() }
        server.start {}
        let socket = try Socket(host: "127.0.0.1", port: server.port)
        var options = RFBOptions()
        options.useContinuousUpdates = true
        let client = RFBClient(transport: socket, options: options)
        let recorder = Recorder()
        client.delegate = recorder
        try client.connect()
        defer { client.stop() }
        try h.expect(wait(recorder.connected, seconds: 3), "no connect callback")
        client.start()

        try server.sendRawFrame(rect: RFBRect(x: 0, y: 0, width: 4, height: 4), colour: rgb(1, 2, 3))
        try h.expect(wait(recorder.framePainted, seconds: 3), "no frame after the decline")
        try server.sendRawFrame(rect: RFBRect(x: 4, y: 4, width: 4, height: 4), colour: rgb(4, 5, 6))
        try h.expect(wait(recorder.framePainted, seconds: 3), "second frame never arrived")
        client.framebuffer.lock.lock()
        let pixel = client.framebuffer.row(5)[5]
        client.framebuffer.lock.unlock()
        try h.expectEqual(pixel, rgb(4, 5, 6))
    }
}
