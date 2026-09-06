import Foundation

/// A saved host. Every field is optional so a config entry can override just
/// the one thing that differs from the command-line defaults.
public struct HostConfig: Codable {
    public var destination: String?
    public var direct: Bool?
    public var port: UInt16?
    public var password: String?
    /// "auto" (Mac backing pixels), "1x" (points), or "WxH".
    public var resolution: String?
    public var swayScale: Double?
    public var commandKey: String?
    public var quality: Int?
    public var compress: Int?
    public var fullscreen: Bool?
    public var sshOptions: [String]?
    public var swayConfig: String?
    public var headlessSway: Bool?

    public init() {}
}

public struct PortholeConfig: Codable {
    public var defaults: HostConfig?
    public var hosts: [String: HostConfig]?

    public init() {}

    public static var path: URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/porthole", isDirectory: true)
        return base.appendingPathComponent("config.json")
    }

    public static func load() -> PortholeConfig {
        guard let data = try? Data(contentsOf: path) else { return PortholeConfig() }
        do {
            return try JSONDecoder().decode(PortholeConfig.self, from: data)
        } catch {
            FileHandle.standardError.write(
                Data("porthole: ignoring malformed \(path.path): \(error)\n".utf8))
            return PortholeConfig()
        }
    }

    public func host(named name: String) -> HostConfig? { hosts?[name] }

    /// Writes a starter config so `--init-config` gives the user something to
    /// edit rather than a blank file.
    public static func writeTemplate() throws -> URL {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var config = PortholeConfig()
        var example = HostConfig()
        example.destination = "you@10.10.0.5"
        example.resolution = "auto"
        example.swayScale = 2
        example.commandKey = "super"
        config.hosts = ["vm": example]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: path)
        return path
    }
}
