import Foundation

public enum RFBError: Error, CustomStringConvertible {
    case handshake(String)
    case authFailed(String)
    case authUnsupported([UInt8])
    case passwordRequired
    case decode(String)
    case protocolViolation(String)

    public var description: String {
        switch self {
        case .handshake(let s): return "handshake failed: \(s)"
        case .authFailed(let s): return "authentication rejected: \(s)"
        case .authUnsupported(let types):
            let list = types.map { t in SecurityType(rawValue: t)?.label ?? "unknown(\(t))" }
            return "no supported auth method; server offered: \(list.joined(separator: ", "))"
        case .passwordRequired: return "server requires a password"
        case .decode(let s): return "decode error: \(s)"
        case .protocolViolation(let s): return "protocol violation: \(s)"
        }
    }
}
