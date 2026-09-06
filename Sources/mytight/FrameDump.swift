import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import MyTightCore

/// `--dump-frame PATH`: connect, wait for the framebuffer to settle, write it
/// to a PNG and exit. No window, no Metal — so it isolates "what did the server
/// actually send" from "what did we draw", which is exactly the question when a
/// session looks blank.
final class FrameDumper: RFBClientDelegate {
    private let path: String
    private let settleSeconds: Double
    private var client: RFBClient?
    private var ssh: SSHSession?
    private let done = DispatchSemaphore(value: 0)
    private var frames = 0
    private let verbose: Bool

    init(path: String, settleSeconds: Double = 3, verbose: Bool) {
        self.path = path
        self.settleSeconds = settleSeconds
        self.verbose = verbose
    }

    /// Diagnostic: drive input from a headless client, so an AppKit event
    /// problem can be told apart from an RFB or compositor one.
    func runInputTest(options: Options) -> Never {
        let digit = Character(options.testKey)
        do {
            let transport = try openTransport(options: options)
            var rfb = RFBOptions()
            rfb.password = options.password
            rfb.useFence = options.useFence
            rfb.useContinuousUpdates = options.useContinuousUpdates
            rfb.trackRemoteCursor = options.trackCursor
            let client = RFBClient(transport: transport, options: rfb)
            client.delegate = self
            client.traceInput = { print("  " + $0) }
            self.client = client
            try client.connect()
            client.start()
            Thread.sleep(forTimeInterval: 1.0)

            print("sending Super+\(digit) (workspace switch)")
            client.sendKey(keysym: Keysym.superL, down: true)
            Thread.sleep(forTimeInterval: 0.05)
            client.sendKey(keysym: Keysym.fromUnicode(digit.unicodeScalars.first!), down: true)
            Thread.sleep(forTimeInterval: 0.05)
            client.sendKey(keysym: Keysym.fromUnicode(digit.unicodeScalars.first!), down: false)
            Thread.sleep(forTimeInterval: 0.05)
            client.sendKey(keysym: Keysym.superL, down: false)
            Thread.sleep(forTimeInterval: 0.6)

            let w = client.framebuffer.width, h = client.framebuffer.height
            print("moving pointer to the centre and clicking")
            client.sendPointer(x: w / 2, y: h / 2, buttonMask: 0)
            Thread.sleep(forTimeInterval: 0.2)
            client.sendPointer(x: w / 2, y: h / 2, buttonMask: 1)
            Thread.sleep(forTimeInterval: 0.1)
            client.sendPointer(x: w / 2, y: h / 2, buttonMask: 0)
            Thread.sleep(forTimeInterval: 0.8)

            print("done — check the remote for a workspace change / pointer move")
            client.stop()
            ssh?.disconnect()
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("mytight: \(describe(error))\n".utf8))
            ssh?.disconnect()
            exit(1)
        }
    }

    private func openTransport(options: Options) throws -> Socket {
        if options.direct {
            let (host, port) = options.directHostAndPort
            return try Socket(host: host, port: port)
        }
        let ssh = SSHSession(destination: options.destination,
                             extraArguments: options.sshOptions)
        self.ssh = ssh
        try ssh.connect()
        let remote = RemoteDesktop(ssh: ssh)
        remote.logger = { print("  \($0)") }
        var launch = RemoteLaunchOptions()
        launch.port = options.port
        launch.reuseExisting = options.reuseExisting
        _ = try remote.ensureServer(options: launch)
        let local = try SSHSession.freeLocalPort()
        try ssh.forward(localPort: local, remoteHost: "127.0.0.1", remotePort: options.port)
        return try Socket(host: "127.0.0.1", port: local)
    }

    func run(options: Options) -> Never {
        do {
            let transport: Socket
            if options.direct {
                let (host, port) = options.directHostAndPort
                transport = try Socket(host: host, port: port)
            } else {
                let ssh = SSHSession(destination: options.destination,
                                     extraArguments: options.sshOptions)
                self.ssh = ssh
                try ssh.connect()
                let remote = RemoteDesktop(ssh: ssh)
                remote.logger = { print("  \($0)") }
                var launch = RemoteLaunchOptions()
                launch.port = options.port
                launch.reuseExisting = options.reuseExisting
                _ = try remote.ensureServer(options: launch)
                let local = try SSHSession.freeLocalPort()
                try ssh.forward(localPort: local, remoteHost: "127.0.0.1", remotePort: options.port)
                transport = try Socket(host: "127.0.0.1", port: local)
            }

            var rfb = RFBOptions()
            rfb.password = options.password
            rfb.compressLevel = options.compress
            rfb.jpegQuality = options.quality
            let client = RFBClient(transport: transport, options: rfb)
            client.delegate = self
            self.client = client
            try client.connect()
            client.start()

            DispatchQueue.global().asyncAfter(deadline: .now() + settleSeconds) { self.done.signal() }
            while done.wait(timeout: .now() + 0.05) != .success {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            try write(client: client)
            client.stop()
            ssh?.disconnect()
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("mytight: \(describe(error))\n".utf8))
            ssh?.disconnect()
            exit(1)
        }
    }

    private func write(client: RFBClient) throws {
        let framebuffer = client.framebuffer
        framebuffer.lock.lock()
        let width = framebuffer.width, height = framebuffer.height
        var pixels = [UInt32](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { raw in
            memcpy(raw.baseAddress!, framebuffer.pixels, width * height * 4)
        }
        framebuffer.lock.unlock()

        // Report what is actually in the buffer, so a blank result is
        // distinguishable from a failed capture.
        var histogram: [UInt32: Int] = [:]
        var nonBlack = 0
        for pixel in pixels {
            let rgbOnly = pixel & 0x00FF_FFFF
            histogram[rgbOnly, default: 0] += 1
            if rgbOnly != 0 { nonBlack += 1 }
        }
        let share = Double(nonBlack) / Double(pixels.count) * 100
        print(String(format: "framebuffer %dx%d — %.2f%% non-black, %d distinct colours, %d frames",
                     width, height, share, histogram.count, frames))
        for (colour, count) in histogram.sorted(by: { $0.value > $1.value }).prefix(4) {
            print(String(format: "   %08X  %.1f%%", colour, Double(count) / Double(pixels.count) * 100))
        }

        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        guard let ctx = pixels.withUnsafeMutableBytes({ raw in
            CGContext(data: raw.baseAddress, width: width, height: height,
                      bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)
        }), let image = ctx.makeImage() else {
            throw RFBError.decode("could not build an image from the framebuffer")
        }
        let url = URL(fileURLWithPath: path)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                         UTType.png.identifier as CFString, 1, nil)
        else { throw RFBError.decode("could not create \(path)") }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw RFBError.decode("could not write \(path)")
        }
        print("wrote \(path)")
    }

    func rfbDidConnect(_ client: RFBClient, width: Int, height: Int, desktopName: String) {
        print("connected: \"\(desktopName)\" \(width)x\(height)")
    }
    func rfbDidUpdateFramebuffer(_ client: RFBClient, dirty: [RFBRect]) {
        frames += 1
        if verbose, frames <= 5 {
            let area = dirty.reduce(0) { $0 + $1.width * $1.height }
            print("  frame \(frames): \(dirty.count) rects, \(area) px")
        }
    }
    func rfbDidResize(_ client: RFBClient, width: Int, height: Int) {
        print("  resized to \(width)x\(height)")
    }
    func rfbDidReceiveCursor(_ client: RFBClient, cursor: CursorImage?) {}
    func rfbDidReceiveClipboard(_ client: RFBClient, text: String) {}
    func rfbDidRing(_ client: RFBClient) {}
    func rfbDidDisconnect(_ client: RFBClient, error: Error?) {
        if let error { print("  disconnected: \(describe(error))") }
    }
    func rfbLog(_ client: RFBClient, message: String) { if verbose { print("  \(message)") } }
}
