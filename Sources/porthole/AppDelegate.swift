import AppKit
import PortholeCore

/// Borderless windows refuse key status unless we insist.
final class SessionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, RFBClientDelegate {
    private let options: Options
    private var window: SessionWindow!
    private var vncView: VNCView!
    private var overlay: StatusOverlay!
    private var statsHUD: StatsHUD!

    private var ssh: SSHSession?
    private var client: RFBClient?
    private var isFullscreen: Bool
    private var lastPasteboardChange = NSPasteboard.general.changeCount
    private var pasteboardTimer: Timer?
    private var statsTimer: Timer?
    private var lastLoggedBytes: UInt64 = 0
    private var hasRequestedResize = false
    /// Once the framebuffer is live, progress messages must never repaint the
    /// overlay — doing so hides the session behind an opaque status card.
    private var isLive = false
    private var reconnectAttempt = 0
    private var isReconnecting = false
    private var resizeDebounce: DispatchWorkItem?
    private var lastRequestedSize: (Int, Int)?

    init(options: Options) {
        self.options = options
        self.isFullscreen = options.fullscreen
        super.init()
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)
        // The window is up before any network work starts, so the session feels
        // immediate even when the SSH handshake takes a moment.
        overlay.show("Connecting to \(options.destination)…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.establish() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        teardown()
    }

    private func buildWindow() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let contentRect = isFullscreen
            ? screen.frame
            : NSRect(x: 0, y: 0, width: 1280, height: 800)

        window = SessionWindow(
            contentRect: contentRect,
            styleMask: isFullscreen ? [.borderless] : [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "porthole — \(options.destination)"
        window.backgroundColor = .black
        // Without this the tracking area never yields mouseMoved, so the
        // remote pointer only moves when a button is held.
        window.acceptsMouseMovedEvents = true
        window.isReleasedWhenClosed = false
        window.delegate = self

        vncView = VNCView(frame: contentRect)
        vncView.autoresizingMask = [.width, .height]
        vncView.commandMapping = options.commandKey
        vncView.hotkeyHandler = { [weak self] event in self?.handleHotkey(event) ?? false }
        window.contentView = vncView

        overlay = StatusOverlay(frame: contentRect)
        overlay.autoresizingMask = [.width, .height]
        vncView.addSubview(overlay)

        statsHUD = StatsHUD()
        vncView.addSubview(statsHUD)
        statsHUD.isHidden = true

        if isFullscreen {
            window.setFrame(screen.frame, display: true)
            window.level = .normal
            NSApp.presentationOptions = [.hideDock, .autoHideMenuBar]
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(vncView)
    }

    // MARK: - Bringing the session up

    private func establish() {
        DispatchQueue.main.async { [weak self] in
            self?.hasRequestedResize = false
            self?.lastRequestedSize = nil
        }
        do {
            let transport: Socket
            if options.direct {
                let (host, port) = options.directHostAndPort
                status("Connecting to \(host):\(port)…")
                transport = try Socket(host: host, port: port)
            } else {
                transport = try connectViaSSH()
            }

            var rfbOptions = RFBOptions()
            rfbOptions.password = options.password
            rfbOptions.compressLevel = options.compress
            rfbOptions.jpegQuality = options.quality
            rfbOptions.trackRemoteCursor = options.trackCursor
            rfbOptions.useFence = options.useFence
            rfbOptions.useContinuousUpdates = options.useContinuousUpdates
            rfbOptions.useExtendedClipboard = true

            let client = RFBClient(transport: transport, options: rfbOptions)
            client.delegate = self
            // Under -v, show every key and pointer event leaving the client, so
            // "the remote ignores my keyboard" can be told apart from "macOS
            // never delivered the event to the view".
            if options.verbose { client.traceInput = { [weak self] in self?.log($0) } }
            self.client = client
            status("Negotiating…")
            try client.connect()
            DispatchQueue.main.async { [weak self] in
                self?.vncView.client = client
                client.start()
            }
        } catch {
            fail(error)
        }
    }

    private func connectViaSSH() throws -> Socket {
        let ssh = SSHSession(destination: options.destination, extraArguments: options.sshOptions)
        if options.verbose { ssh.logger = { [weak self] in self?.log($0) } }
        self.ssh = ssh

        status("Opening SSH connection…")
        try ssh.connect()

        let remote = RemoteDesktop(ssh: ssh)
        remote.logger = { [weak self] message in
            self?.status(message)
            self?.log(message)
        }

        var launch = RemoteLaunchOptions()
        launch.port = options.port
        launch.allowHeadlessSway = options.headlessSway
        launch.swayConfig = options.swayConfig
        launch.reuseExisting = options.reuseExisting
        // With --direct-vnc the server has to listen somewhere NetBird can
        // reach, but binding 0.0.0.0 would expose it on every interface the VM
        // has. Bind exactly the address we are already talking to instead.
        launch.bindAddress = options.directVNC ? options.sshHostOnly : "127.0.0.1"

        status("Starting the remote desktop…")
        _ = try remote.ensureServer(options: launch)
        self.remoteDesktop = remote

        if options.directVNC {
            let host = options.sshHostOnly
            status("Connecting directly to \(host):\(options.port)…")
            return try Socket(host: host, port: options.port)
        }

        let localPort = try SSHSession.freeLocalPort()
        try ssh.forward(localPort: localPort, remoteHost: "127.0.0.1", remotePort: options.port)
        status("Connecting through the tunnel…")
        return try Socket(host: "127.0.0.1", port: localPort)
    }

    private var remoteDesktop: RemoteDesktop?

    /// Asks the compositor to match this display, then sets sway's scale so the
    /// extra pixels become sharpness instead of tiny text.
    private func applyResolution() {
        guard !hasRequestedResize else { return }
        hasRequestedResize = true
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens[0]
        guard let (width, height) = options.resolution.pixels(for: screen) else { return }
        lastRequestedSize = (width, height)
        client?.requestDesktopSize(width: width, height: height)

        let scale: Double
        if let explicit = options.swayScale {
            scale = explicit
        } else if case .auto = options.resolution {
            scale = Double(screen.backingScaleFactor)
        } else {
            scale = 1
        }
        guard scale > 0, let remoteDesktop else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            remoteDesktop.setOutputScale(scale)
        }
    }

    // MARK: - RFBClientDelegate

    func rfbDidConnect(_ client: RFBClient, width: Int, height: Int, desktopName: String) {
        isLive = true
        reconnectAttempt = 0
        overlay.hide()
        window.title = "porthole — \(desktopName)"
        vncView.framebufferDidResize()
        applyResolution()
        startPasteboardWatch()
        if options.verbose { startStatsLog() }
    }

    func rfbDidUpdateFramebuffer(_ client: RFBClient, dirty: [RFBRect]) {
        vncView.enqueue(dirty: dirty)
        statsHUD.update(stats: client.currentStats(),
                        size: (client.framebuffer.width, client.framebuffer.height))
    }

    func rfbDidResize(_ client: RFBClient, width: Int, height: Int) {
        vncView.framebufferDidResize()
        log("remote resolution is now \(width)x\(height)")
    }

    func rfbDidReceiveCursor(_ client: RFBClient, cursor: CursorImage?) {
        vncView.applyRemoteCursor(cursor)
    }

    func rfbDidReceiveClipboard(_ client: RFBClient, text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastPasteboardChange = pasteboard.changeCount
    }

    func rfbDidRing(_ client: RFBClient) { NSSound.beep() }

    func rfbDidDisconnect(_ client: RFBClient, error: Error?) {
        guard options.autoReconnect else {
            if let error { fail(error) } else { NSApp.terminate(nil) }
            return
        }
        // A clean close is either our own teardown or the server going away;
        // either way the session is over, so only retry on an error.
        guard let error else {
            log("disconnected")
            NSApp.terminate(nil)
            return
        }
        scheduleReconnect(after: error)
    }

    /// Retries with a backoff that stays responsive for a brief blip but does
    /// not hammer a host that is genuinely gone.
    private func scheduleReconnect(after error: Error) {
        guard !isReconnecting else { return }
        isReconnecting = true
        isLive = false
        reconnectAttempt += 1
        let delay = min(pow(1.6, Double(reconnectAttempt - 1)), 20.0)
        let reason = describe(error)
        log("connection lost: \(reason)")

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.client?.stop()
            self.client = nil
            self.lastLoggedBytes = 0
            self.vncView.client = nil
            self.vncView.framebufferDidResize()
            self.ssh?.disconnect()
            self.ssh = nil
            self.remoteDesktop = nil
            self.overlay.show(String(format: "Reconnecting in %.0fs — %@", delay, reason))
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.isReconnecting = false
            self.status("Reconnecting…")
            self.establish()
        }
    }

    func rfbLog(_ client: RFBClient, message: String) { log(message) }

    // MARK: - Clipboard

    /// AppKit has no pasteboard-changed notification, so poll the change count.
    private func startPasteboardWatch() {
        pasteboardTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            guard let self else { return }
            let pasteboard = NSPasteboard.general
            guard pasteboard.changeCount != self.lastPasteboardChange else { return }
            self.lastPasteboardChange = pasteboard.changeCount
            guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
            self.client?.sendClipboard(text)
        }
    }

    /// Under -v, a periodic line showing what the link is actually costing —
    /// the quickest way to decide between --quality, --compress and --lossless.
    private func startStatsLog() {
        statsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, let client = self.client else { return }
            let stats = client.currentStats()
            // A reconnect restarts the byte counter, so guard the subtraction;
            // wrapping produced an "8 EB/s" readout.
            if stats.bytesReceived < self.lastLoggedBytes { self.lastLoggedBytes = 0 }
            let delta = stats.bytesReceived - self.lastLoggedBytes
            self.lastLoggedBytes = stats.bytesReceived
            let rate = ByteCountFormatter.string(fromByteCount: Int64(delta / 2), countStyle: .binary)
            self.log(String(format: "%d×%d %@  %llu frames  %.1f ms/frame  %@/s",
                            client.framebuffer.width, client.framebuffer.height,
                            stats.encodingName, stats.framesDecoded,
                            stats.lastFrameMilliseconds, rate))
        }
    }

    /// Reshapes the remote to match the window. Debounced, because a live drag
    /// emits a resize per frame and each one would be a full desktop
    /// reconfiguration on the far end.
    private func scheduleRemoteResize() {
        guard options.liveResize, isLive else { return }
        switch options.resolution {
        case .keep, .explicit: return    // the user pinned a size; respect it
        case .auto, .points: break
        }
        resizeDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.applyWindowSizeToRemote() }
        resizeDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func applyWindowSizeToRemote() {
        guard let client, isLive else { return }
        let scale: CGFloat
        if case .points = options.resolution { scale = 1 } else { scale = window.backingScaleFactor }
        let size = vncView.bounds.size
        let width = Int((size.width * scale).rounded())
        let height = Int((size.height * scale).rounded())
        guard width > 16, height > 16 else { return }
        // Skip no-ops: the remote already matches, or we just asked for this.
        if let last = lastRequestedSize, last == (width, height) { return }
        if client.framebuffer.width == width && client.framebuffer.height == height { return }
        lastRequestedSize = (width, height)
        client.requestDesktopSize(width: width, height: height)
    }

    // MARK: - Hotkeys

    private func handleHotkey(_ event: NSEvent) -> Bool {
        let required: NSEvent.ModifierFlags = [.control, .option, .command]
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).isSuperset(of: required)
        else { return false }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "f": toggleFullscreen(); return true
        case "i": statsHUD.isHidden.toggle(); return true
        case "q": NSApp.terminate(nil); return true
        case "r":
            hasRequestedResize = false
            applyResolution()
            return true
        default: return false
        }
    }

    private func toggleFullscreen() {
        vncView.releaseAllKeys()
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens[0]
        isFullscreen.toggle()

        // Rebuilding the window is the quickest way to swap style masks without
        // the Spaces animation a native full-screen transition would impose.
        let previousView = vncView!
        previousView.removeFromSuperview()
        overlay.removeFromSuperview()
        statsHUD.removeFromSuperview()

        let frame = isFullscreen ? screen.frame : NSRect(x: 0, y: 0, width: 1280, height: 800)
        let newWindow = SessionWindow(
            contentRect: frame,
            styleMask: isFullscreen ? [.borderless] : [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        newWindow.title = window.title
        newWindow.backgroundColor = .black
        newWindow.acceptsMouseMovedEvents = true
        newWindow.isReleasedWhenClosed = false
        newWindow.delegate = self

        previousView.frame = NSRect(origin: .zero, size: frame.size)
        newWindow.contentView = previousView
        overlay.frame = previousView.bounds
        previousView.addSubview(overlay)
        previousView.addSubview(statsHUD)

        let old = window
        window = newWindow
        NSApp.presentationOptions = isFullscreen ? [.hideDock, .autoHideMenuBar] : []
        newWindow.makeKeyAndOrderFront(nil)
        newWindow.makeFirstResponder(previousView)
        if !isFullscreen { newWindow.center() }
        old?.orderOut(nil)
    }

    // MARK: - Status plumbing

    /// Connection progress. Deliberately inert once the session is up: the
    /// remote launcher keeps logging (setting the output scale, for one) after
    /// the first frame has already been drawn.
    private func status(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isLive else { return }
            self.overlay.show(message)
        }
    }

    private func log(_ message: String) {
        guard options.verbose else { return }
        FileHandle.standardError.write(Data("porthole: \(message)\n".utf8))
    }

    private func fail(_ error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let text = describe(error)
            self.isLive = false
            self.overlay.showError(text)
            FileHandle.standardError.write(Data("porthole: \(text)\n".utf8))
        }
    }

    private func teardown() {
        pasteboardTimer?.invalidate()
        statsTimer?.invalidate()
        vncView?.releaseAllKeys()
        client?.stop()
        ssh?.disconnect()
    }
}

/// Our own error types carry the useful message in `description`; anything
/// else is a Cocoa error whose `localizedDescription` is the readable one.
func describe(_ error: Error) -> String {
    switch error {
    case let error as SocketError: return error.description
    case let error as RFBError: return error.description
    case let error as SSHError: return error.description
    case let error as RemoteError: return error.description
    default: return error.localizedDescription
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    /// A modifier held while focus leaves would otherwise stay latched on the
    /// remote until the next press.
    func windowDidResignKey(_ notification: Notification) {
        vncView?.releaseAllKeys()
    }

    func windowDidResize(_ notification: Notification) {
        scheduleRemoteResize()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        scheduleRemoteResize()
    }
}
