import AppKit
import PortholeCore

enum Resolution {
    /// The Mac's backing-store pixels — a 1:1 map with no resampling.
    case auto
    /// Logical points; a quarter of the pixels on Retina, for slow links.
    case points
    case explicit(Int, Int)
    case keep

    static func parse(_ value: String) -> Resolution? {
        switch value.lowercased() {
        case "auto", "native", "2x": return .auto
        case "1x", "points", "logical": return .points
        case "keep", "none": return .keep
        default:
            let parts = value.lowercased().split(separator: "x")
            guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]),
                  w > 0, h > 0, w <= 16384, h <= 16384 else { return nil }
            return .explicit(w, h)
        }
    }

    /// RFB carries pixels, so the Retina case asks the remote for the full
    /// backing resolution and lets sway's own `scale 2` keep text readable.
    func pixels(for screen: NSScreen) -> (Int, Int)? {
        switch self {
        case .auto:
            let scale = screen.backingScaleFactor
            return (Int(screen.frame.width * scale), Int(screen.frame.height * scale))
        case .points:
            return (Int(screen.frame.width), Int(screen.frame.height))
        case .explicit(let w, let h):
            return (w, h)
        case .keep:
            return nil
        }
    }
}

struct Options {
    var destination = ""
    var direct = false
    /// Start the server over SSH but carry pixels outside the tunnel — right
    /// when the network already encrypts the path (a WireGuard mesh, say).
    var directVNC = false
    var port: UInt16 = 5900
    var password: String?
    var resolution: Resolution = .auto
    var swayScale: Double?
    var commandKey: CommandKeyMapping = .superKey
    var quality: Int? = 8
    var compress: Int? = 6
    var lossless = false
    var trackCursor = true
    var useFence = true
    var useContinuousUpdates = false
    /// Reconnect automatically when the link drops.
    var autoReconnect = true
    /// Follow window resizes by reshaping the remote desktop.
    var liveResize = true
    /// Capture the keys macOS reserves (Cmd-Tab, Cmd-Space, Cmd-Q) so they
    /// reach the remote. Engages when you click into the window.
    var grabKeyboard = true
    var fullscreen = true
    var headlessSway = true
    var swayConfig: String?
    var sshOptions: [String] = []
    var verbose = false
    var reuseExisting = true
    /// Diagnostic: write the framebuffer to this path and exit.
    var dumpFrame: String?
    /// Diagnostic: send input from a headless client and exit.
    var testInput = false
    /// Digit sent with Super during --test-input.
    var testKey = "3"

    static let usage = """
    porthole — a native macOS VNC client for wayvnc/sway

    USAGE
      porthole <user@host | saved-name> [options]
      porthole --direct <host[:port]> [options]

    By default porthole opens one multiplexed SSH connection, starts wayvnc on the
    far end (bringing up a headless sway first if nothing is running), forwards the
    port to loopback, and opens a full-screen native window sized to this display.

    CONNECTION
      --direct              Connect straight to host:port; do not use SSH at all.
      --direct-vnc          Use SSH to start the server, then connect to host:port
                            directly instead of through the tunnel. Worth it when
                            the network is already private and encrypted, where
                            the extra hop only costs latency.
      --port N              Remote VNC port (default 5900).
      --password P          VNC password. Also read from $PORTHOLE_PASSWORD.
      --ssh-opt ARG         Extra argument passed to ssh. Repeatable.
      --no-reuse            Always start a fresh wayvnc, never adopt a running one.

    DISPLAY
      --res auto|1x|WxH     Remote resolution. "auto" (default) asks for this
                            Mac's full backing resolution; "1x" asks for logical
                            points; "WxH" is explicit; "keep" leaves it alone.
      --scale N             sway output scale to set (default 2 with --res auto,
                            1 otherwise). Use 0 to leave the scale untouched.
      --window              Windowed instead of full screen.
      --no-cursor           Draw the local pointer instead of the remote's.
      --no-reconnect        Exit when the connection drops instead of retrying.
      --no-live-resize      Do not reshape the remote when the window resizes.
      --no-grab             Never capture the keys macOS reserves for itself.
      --continuous          Ask the server to push frames without a request per
                            frame. Saves one round trip; off by default because
                            some servers mishandle it.

    QUALITY
      --quality 0-9         Tight JPEG quality, 9 best (default 8).
      --compress 0-9        zlib level, 9 smallest and slowest (default 6).
      --lossless            Disable JPEG entirely; costs bandwidth, gains text
                            crispness on a fast link.

    REMOTE
      --no-headless-sway    Fail rather than starting sway when nothing is running.
      --sway-config PATH    Config for the headless sway instance.
      --cmd-key super|ctrl|alt
                            What the Mac Command key becomes (default super, so
                            sway's $mod bindings work under your thumb).

    DIAGNOSTICS
      --dump-frame PATH     Connect, wait for the screen to settle, write the
                            decoded framebuffer to a PNG and exit. No window is
                            opened, so this separates "what the server sent"
                            from "what we drew" when a session looks blank.

    OTHER
      --init-config         Write a starter ~/.config/porthole/config.json.
      -v, --verbose         Log the handshake and remote commands.
      -V, --version         Print the version and exit.
      -h, --help            This text.

    IN-SESSION KEYS
      ^⌥⌘F   toggle full screen        ^⌥⌘I   toggle the stats overlay
      ^⌥⌘Q   disconnect                ^⌥⌘R   re-send the resolution request
      ^⌥⌘G   release the keyboard grab

    KEYBOARD GRAB
      Clicking into the window captures the keyboard, so ⌘Tab, ⌘Space, ⌘Q and
      ⌘C go to the remote instead of macOS — the session behaves like a real
      machine. Press ^⌥⌘G to hand the keyboard back; the grab is also released
      whenever the window loses focus, so it can never strand you.

      This needs Accessibility permission, which macOS will ask for the first
      time the grab engages. Use --no-grab to switch the whole thing off.
    """

    /// Command line wins over the saved host, which wins over `defaults`.
    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var positional: [String] = []
        var explicitFlags = Set<String>()

        var index = 0
        func next(_ flag: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw CLIError.missingValue(flag) }
            return arguments[index]
        }

        while index < arguments.count {
            let argument = arguments[index]
            explicitFlags.insert(argument)
            switch argument {
            case "-h", "--help": throw CLIError.showUsage
            case "-V", "--version": throw CLIError.showVersion
            case "--init-config": throw CLIError.initConfig
            case "-v", "--verbose": options.verbose = true
            case "--direct": options.direct = true
            case "--direct-vnc": options.directVNC = true
            case "--window": options.fullscreen = false
            case "--no-cursor": options.trackCursor = false
            case "--no-fence": options.useFence = false
            case "--continuous": options.useContinuousUpdates = true
            case "--no-reconnect": options.autoReconnect = false
            case "--no-live-resize": options.liveResize = false
            case "--no-grab": options.grabKeyboard = false
            case "--lossless": options.lossless = true
            case "--no-reuse": options.reuseExisting = false
            case "--no-headless-sway": options.headlessSway = false
            case "--port": options.port = UInt16(try next(argument)) ?? 5900
            case "--password": options.password = try next(argument)
            case "--ssh-opt": options.sshOptions.append(try next(argument))
            case "--sway-config": options.swayConfig = try next(argument)
            case "--dump-frame": options.dumpFrame = try next(argument)
            case "--test-input": options.testInput = true
            case "--test-key": options.testKey = try next(argument)
            case "--scale": options.swayScale = Double(try next(argument))
            case "--quality": options.quality = Int(try next(argument))
            case "--compress": options.compress = Int(try next(argument))
            case "--res":
                let value = try next(argument)
                guard let resolution = Resolution.parse(value) else {
                    throw CLIError.badValue("--res", value)
                }
                options.resolution = resolution
            case "--cmd-key":
                let value = try next(argument)
                guard let mapping = CommandKeyMapping(rawValue: value) else {
                    throw CLIError.badValue("--cmd-key", value)
                }
                options.commandKey = mapping
            default:
                guard !argument.hasPrefix("-") else { throw CLIError.unknownFlag(argument) }
                positional.append(argument)
            }
            index += 1
        }

        guard let target = positional.first else { throw CLIError.showUsage }

        // A bare name that is not user@host or host:port may name a saved host.
        let config = PortholeConfig.load()
        let saved = config.host(named: target)
        options.apply(config.defaults, explicit: explicitFlags)
        options.apply(saved, explicit: explicitFlags)
        options.destination = saved?.destination ?? target

        if options.password == nil, let environment = ProcessInfo.processInfo.environment["PORTHOLE_PASSWORD"] {
            options.password = environment
        }
        if options.lossless { options.quality = nil }
        return options
    }

    private mutating func apply(_ host: HostConfig?, explicit: Set<String>) {
        guard let host else { return }
        if let value = host.direct, !explicit.contains("--direct") { direct = value }
        if let value = host.port, !explicit.contains("--port") { port = value }
        if let value = host.password, !explicit.contains("--password") { password = value }
        if let value = host.quality, !explicit.contains("--quality") { quality = value }
        if let value = host.compress, !explicit.contains("--compress") { compress = value }
        if let value = host.fullscreen, !explicit.contains("--window") { fullscreen = value }
        if let value = host.swayScale, !explicit.contains("--scale") { swayScale = value }
        if let value = host.swayConfig, !explicit.contains("--sway-config") { swayConfig = value }
        if let value = host.headlessSway, !explicit.contains("--no-headless-sway") { headlessSway = value }
        if let value = host.sshOptions, !explicit.contains("--ssh-opt") { sshOptions = value }
        if let value = host.resolution, !explicit.contains("--res"),
           let parsed = Resolution.parse(value) { resolution = parsed }
        if let value = host.commandKey, !explicit.contains("--cmd-key"),
           let parsed = CommandKeyMapping(rawValue: value) { commandKey = parsed }
    }

    /// Splits `host:port` while leaving bare IPv6 literals alone.
    var directHostAndPort: (String, UInt16) {
        if destination.hasPrefix("[") , let close = destination.firstIndex(of: "]") {
            let host = String(destination[destination.index(after: destination.startIndex)..<close])
            let rest = destination[destination.index(after: close)...]
            if rest.hasPrefix(":"), let value = UInt16(rest.dropFirst()) { return (host, value) }
            return (host, port)
        }
        let parts = destination.split(separator: ":")
        if parts.count == 2, let value = UInt16(parts[1]) { return (String(parts[0]), value) }
        return (destination, port)
    }

    /// The host part of an ssh destination, for the `--direct-vnc` hop.
    var sshHostOnly: String {
        destination.contains("@") ? String(destination.split(separator: "@").last!) : destination
    }
}

enum CLIError: Error {
    case showUsage
    case showVersion
    case initConfig
    case missingValue(String)
    case unknownFlag(String)
    case badValue(String, String)
}
