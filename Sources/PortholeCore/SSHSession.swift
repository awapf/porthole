import Foundation

public struct CommandResult {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var succeeded: Bool { status == 0 }
}

public enum SSHError: Error, CustomStringConvertible {
    case masterFailed(String)
    case commandFailed(String, Int32, String)
    case forwardFailed(String)
    case noFreePort

    public var description: String {
        switch self {
        case .masterFailed(let s): return "ssh connection failed: \(s)"
        case .commandFailed(let cmd, let code, let err):
            return "remote command failed (\(code)): \(cmd)\n\(err)"
        case .forwardFailed(let s): return "port forward failed: \(s)"
        case .noFreePort: return "no free local port"
        }
    }
}

/// A multiplexed SSH connection.
///
/// Everything — probing, launching, tunnelling — rides one authenticated
/// master connection, so connecting costs a single handshake even when the
/// launcher runs several remote commands.
public final class SSHSession {
    public let destination: String
    private let controlPath: String
    private let extraArguments: [String]
    private var masterUp = false
    public var logger: ((String) -> Void)?

    public init(destination: String, extraArguments: [String] = []) {
        self.destination = destination
        self.extraArguments = extraArguments
        let digest = abs(destination.hashValue)
        self.controlPath = NSTemporaryDirectory() + "porthole-\(digest).sock"
    }

    private var baseArguments: [String] {
        ["-o", "ControlPath=\(controlPath)"] + extraArguments
    }

    /// Opens the master connection. `BatchMode` stays off so passphrase and
    /// host-key prompts still reach the user's terminal.
    public func connect(timeout: Int = 20) throws {
        var args = baseArguments
        args += [
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=120",
            "-o", "ConnectTimeout=\(timeout)",
            "-o", "ServerAliveInterval=15",
            "-N", "-f",
            destination,
        ]
        logger?("ssh " + args.joined(separator: " "))
        let result = try runProcess("/usr/bin/ssh", args)
        guard result.succeeded else {
            throw SSHError.masterFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        masterUp = true
    }

    @discardableResult
    public func run(_ command: String) throws -> CommandResult {
        let args = baseArguments + [destination, command]
        return try runProcess("/usr/bin/ssh", args)
    }

    public func runChecked(_ command: String) throws -> String {
        let result = try run(command)
        guard result.succeeded else {
            throw SSHError.commandFailed(command, result.status, result.stderr)
        }
        return result.stdout
    }

    /// Adds a forward to the live master connection, so no second SSH process
    /// hangs around holding the tunnel.
    public func forward(localPort: UInt16, remoteHost: String, remotePort: UInt16) throws {
        let spec = "127.0.0.1:\(localPort):\(remoteHost):\(remotePort)"
        let args = baseArguments + ["-O", "forward", "-L", spec, destination]
        let result = try runProcess("/usr/bin/ssh", args)
        guard result.succeeded else {
            throw SSHError.forwardFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        logger?("tunnel 127.0.0.1:\(localPort) -> \(remoteHost):\(remotePort)")
    }

    public func disconnect() {
        guard masterUp else { return }
        masterUp = false
        let args = baseArguments + ["-O", "exit", destination]
        _ = try? runProcess("/usr/bin/ssh", args)
    }

    /// Asks the kernel for an unused loopback port.
    public static func freeLocalPort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SSHError.noFreePort }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Foundation.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw SSHError.noFreePort }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else { throw SSHError.noFreePort }
        return UInt16(bigEndian: actual.sin_port)
    }

    private func runProcess(_ path: String, _ arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()

        // Drain both pipes concurrently; a chatty stderr would otherwise fill
        // its buffer and deadlock the child.
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave()
        }
        process.waitUntilExit()
        group.wait()

        return CommandResult(
            status: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}
