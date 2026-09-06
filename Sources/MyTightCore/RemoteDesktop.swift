import Foundation

/// What a probe found on the far end.
public struct RemoteState {
    public var uid: String = ""
    public var runtimeDir: String = ""
    public var waylandDisplays: [String] = []
    public var binaries: [String: String] = [:]
    public var wayvncRunning = false
    public var swayRunning = false
    public var portOpen = false
    public var distro = ""
    public var os = ""

    public func has(_ binary: String) -> Bool { binaries[binary] != nil }
    public var waylandDisplay: String? { waylandDisplays.first }
}

public enum RemoteError: Error, CustomStringConvertible {
    case noWayvnc(String)
    case noCompositor(String)
    case startupTimeout(String)
    case unsupported(String)

    public var description: String {
        switch self {
        case .noWayvnc(let host):
            return """
            \(host) has no `wayvnc` on PATH.
            Install it there, e.g.  apt install wayvnc   /   pacman -S wayvnc
            """
        case .noCompositor(let host):
            return "\(host) has no Wayland session and no `sway` to start one"
        case .startupTimeout(let what): return "timed out waiting for \(what)"
        case .unsupported(let s): return s
        }
    }
}

public struct RemoteLaunchOptions {
    public var port: UInt16 = 5900
    /// Bind address for wayvnc on the remote. Loopback is right for an SSH
    /// tunnel. For a direct connection this should be the specific NetBird
    /// address, never 0.0.0.0 — the VM may have interfaces you did not mean to
    /// serve on.
    public var bindAddress = "127.0.0.1"
    /// Start a headless sway when no Wayland session is running.
    public var allowHeadlessSway = true
    public var swayConfig: String?
    /// Reuse a wayvnc that is already serving rather than starting another.
    public var reuseExisting = true
    public init() {}
}

/// Brings a wayvnc server up on the far end and reports how to reach it.
public final class RemoteDesktop {
    private let ssh: SSHSession
    public var logger: ((String) -> Void)?
    /// Kept from the last probe so the swaymsg helpers know the runtime dir.
    private var lastState: RemoteState?

    public init(ssh: SSHSession) { self.ssh = ssh }

    /// Environment prefix for `swaymsg`.
    ///
    /// A non-interactive SSH session inherits none of the compositor's
    /// environment, and swaymsg fails with "Unable to retrieve socket path"
    /// unless SWAYSOCK is discovered explicitly.
    private func swayEnvironment() -> String {
        let runtime = lastState?.runtimeDir ?? "/run/user/$(id -u)"
        var prefix = "export XDG_RUNTIME_DIR=\(shellQuote(runtime)); "
        if let display = lastState?.waylandDisplay {
            prefix += "export WAYLAND_DISPLAY=\(shellQuote(display)); "
        }
        prefix += "export SWAYSOCK=\"${SWAYSOCK:-$(ls -t \"$XDG_RUNTIME_DIR\"/sway-ipc.*.sock 2>/dev/null | head -1)}\"; "
        return prefix
    }

    // MARK: - Probe

    /// One round trip that answers every question the launcher needs.
    public func probe(port: UInt16) throws -> RemoteState {
        let script = """
        uid=$(id -u)
        rt="${XDG_RUNTIME_DIR:-/run/user/$uid}"
        echo "uid=$uid"
        echo "runtime=$rt"
        echo "os=$(uname -s)"
        if [ -r /etc/os-release ]; then . /etc/os-release; echo "distro=${PRETTY_NAME:-$NAME}"; fi
        for b in wayvnc sway swaymsg wayvncctl; do
          p=$(command -v "$b" 2>/dev/null) && echo "bin.$b=$p"
        done
        for s in "$rt"/wayland-*; do
          [ -S "$s" ] && echo "wayland=$(basename "$s")"
        done
        pgrep -x wayvnc >/dev/null 2>&1 && echo "wayvnc_running=1" || echo "wayvnc_running=0"
        pgrep -x sway >/dev/null 2>&1 && echo "sway_running=1" || echo "sway_running=0"
        if command -v ss >/dev/null 2>&1; then
          ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE '[:.]\(port)$' \\
            && echo "port_open=1" || echo "port_open=0"
        elif command -v netstat >/dev/null 2>&1; then
          netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE '[:.]\(port)$' \\
            && echo "port_open=1" || echo "port_open=0"
        else
          echo "port_open=unknown"
        fi
        """
        let output = try ssh.runChecked(script)
        var state = RemoteState()
        defer { lastState = state }
        for line in output.split(separator: "\n") {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<separator])
            let value = String(line[line.index(after: separator)...])
            switch key {
            case "uid": state.uid = value
            case "runtime": state.runtimeDir = value
            case "os": state.os = value
            case "distro": state.distro = value
            case "wayland": state.waylandDisplays.append(value)
            case "wayvnc_running": state.wayvncRunning = value == "1"
            case "sway_running": state.swayRunning = value == "1"
            case "port_open": state.portOpen = value == "1"
            default:
                if key.hasPrefix("bin.") { state.binaries[String(key.dropFirst(4))] = value }
            }
        }
        return state
    }

    // MARK: - Launch

    /// Ensures something is serving RFB on `options.port`, starting a headless
    /// sway first if the VM has no Wayland session yet.
    @discardableResult
    public func ensureServer(options: RemoteLaunchOptions) throws -> RemoteState {
        var state = try probe(port: options.port)
        log("remote: \(state.distro.isEmpty ? state.os : state.distro), uid \(state.uid)")

        if state.portOpen && options.reuseExisting {
            log("wayvnc already serving on port \(options.port) — reusing it")
            return state
        }
        guard state.has("wayvnc") else { throw RemoteError.noWayvnc(ssh.destination) }

        if state.waylandDisplay == nil {
            guard options.allowHeadlessSway else { throw RemoteError.noCompositor(ssh.destination) }
            guard state.has("sway") else { throw RemoteError.noCompositor(ssh.destination) }
            log("no Wayland session found — starting headless sway")
            try startHeadlessSway(state: state, options: options)
            state = try waitForWaylandSocket(port: options.port)
        } else {
            log("attaching to Wayland session \(state.waylandDisplay!)")
        }

        if state.wayvncRunning && !state.portOpen {
            log("a wayvnc is running but not serving \(options.port); starting another")
        }
        try startWayvnc(state: state, options: options)
        try waitForPort(options.port)
        return state
    }

    private func startHeadlessSway(state: RemoteState, options: RemoteLaunchOptions) throws {
        let configArgument = options.swayConfig.map { "-c \(shellQuote($0))" } ?? ""
        let script = """
        mkdir -p "$HOME/.cache"
        export XDG_RUNTIME_DIR=\(shellQuote(state.runtimeDir))
        export WLR_BACKENDS=headless
        export WLR_LIBINPUT_NO_DEVICES=1
        export XDG_SESSION_TYPE=wayland
        setsid nohup sway \(configArgument) > "$HOME/.cache/mytight-sway.log" 2>&1 < /dev/null &
        echo started
        """
        _ = try ssh.runChecked(script)
    }

    private func startWayvnc(state: RemoteState, options: RemoteLaunchOptions) throws {
        // Re-probe so a sway we just started contributes its socket.
        let display = try (state.waylandDisplay ?? probe(port: options.port).waylandDisplay) ?? "wayland-1"
        let script = """
        mkdir -p "$HOME/.cache"
        export XDG_RUNTIME_DIR=\(shellQuote(state.runtimeDir))
        export WAYLAND_DISPLAY=\(shellQuote(display))
        setsid nohup wayvnc \(shellQuote(options.bindAddress)) \(options.port) \\
            > "$HOME/.cache/mytight-wayvnc.log" 2>&1 < /dev/null &
        echo started
        """
        if options.bindAddress != "127.0.0.1" {
            log("note: wayvnc will accept connections on \(options.bindAddress), not just loopback")
        }
        log("starting wayvnc on \(options.bindAddress):\(options.port) against \(display)")
        _ = try ssh.runChecked(script)
    }

    private func waitForWaylandSocket(port: UInt16, timeout: TimeInterval = 10) throws -> RemoteState {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let state = try probe(port: port)
            if state.waylandDisplay != nil { return state }
            Thread.sleep(forTimeInterval: 0.4)
        }
        throw RemoteError.startupTimeout("the sway Wayland socket (see ~/.cache/mytight-sway.log on the remote)")
    }

    private func waitForPort(_ port: UInt16, timeout: TimeInterval = 10) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try probe(port: port).portOpen { return }
            Thread.sleep(forTimeInterval: 0.4)
        }
        throw RemoteError.startupTimeout("wayvnc to listen on \(port) (see ~/.cache/mytight-wayvnc.log on the remote)")
    }

    // MARK: - Output geometry

    /// The name of the output wayvnc is capturing, e.g. `HEADLESS-1`.
    public func firstOutputName() -> String? {
        let command = swayEnvironment() + "swaymsg -t get_outputs -r 2>/dev/null"
        guard let json = try? ssh.run(command), json.succeeded,
              let data = json.stdout.data(using: .utf8),
              let outputs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        return outputs.first?["name"] as? String
    }

    /// Sets the compositor's scale factor. On a Retina Mac the remote runs at
    /// full backing resolution with `scale 2`, which is what makes the session
    /// look like a local display rather than an upscaled one.
    public func setOutputScale(_ scale: Double, output: String? = nil) {
        guard let name = output ?? firstOutputName() else { return }
        let command = swayEnvironment() + "swaymsg output \(shellQuote(name)) scale \(scale)"
        let result = try? ssh.run(command)
        if result?.succeeded == true {
            log("set \(name) scale to \(scale)")
        } else {
            log("could not set \(name) scale: \(result?.stderr.trimmingCharacters(in: .whitespacesAndNewlines) ?? "swaymsg failed")")
        }
    }

    private func log(_ message: String) { logger?(message) }
}

/// Single-quote for POSIX shells, escaping embedded quotes.
public func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
