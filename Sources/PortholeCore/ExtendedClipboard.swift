import Foundation

/// RFB extended clipboard (pseudo-encoding 0xC0A1E5CE).
///
/// The legacy `ServerCutText` / `ClientCutText` messages are Latin-1 by
/// specification, so anything outside it — accented letters, dashes, emoji —
/// is destroyed in transit. This extension carries zlib-compressed UTF-8
/// instead.
///
/// neatvnc advertises a maximum unsolicited size of zero, which means a peer
/// must not push clipboard content directly. The exchange is instead:
/// **notify** ("I have something") → **request** → **provide** (the content).
public enum ExtClipboard {
    public static let encoding: Int32 = -1063131698   // 0xC0A1E5CE

    public struct Flags: OptionSet {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let text = Flags(rawValue: 1 << 0)
        public static let rtf = Flags(rawValue: 1 << 1)
        public static let html = Flags(rawValue: 1 << 2)
        public static let dib = Flags(rawValue: 1 << 3)
        public static let files = Flags(rawValue: 1 << 4)
        public static let caps = Flags(rawValue: 1 << 24)
        public static let request = Flags(rawValue: 1 << 25)
        public static let peek = Flags(rawValue: 1 << 26)
        public static let notify = Flags(rawValue: 1 << 27)
        public static let provide = Flags(rawValue: 1 << 28)
        public static let allActions: Flags = [.request, .peek, .notify, .provide]
    }

    /// Human-readable flag list, for tracing the exchange.
    public static func describe(_ flags: Flags) -> String {
        var parts: [String] = []
        if flags.contains(.caps) { parts.append("caps") }
        if flags.contains(.request) { parts.append("request") }
        if flags.contains(.peek) { parts.append("peek") }
        if flags.contains(.notify) { parts.append("notify") }
        if flags.contains(.provide) { parts.append("provide") }
        if flags.contains(.text) { parts.append("text") }
        return parts.isEmpty ? String(format: "0x%08x", flags.rawValue) : parts.joined(separator: "|")
    }

    /// Largest payload we will accept, matching neatvnc's own cap.
    public static let maxPayload = 1 << 20

    /// Body of a caps message: our supported actions plus, for each supported
    /// format, the largest unsolicited payload we will accept.
    public static func capsBody(maxUnsolicitedText: UInt32) -> [UInt8] {
        var out = MessageBuilder()
        out.u32(Flags([.caps, .text]).union(.allActions).rawValue)
        out.u32(maxUnsolicitedText)
        return out.bytes
    }

    /// A bare action message (notify, request or peek) with no payload.
    public static func actionBody(_ flags: Flags) -> [UInt8] {
        var out = MessageBuilder()
        out.u32(flags.rawValue)
        return out.bytes
    }

    /// A provide message: zlib(u32 length + CRLF text + NUL terminator).
    /// The terminator is not optional — neatvnc rejects the message without it.
    public static func provideBody(text: String, deflater: Deflater) throws -> [UInt8] {
        var payload = [UInt8](lfToCRLF(text).utf8)
        payload.append(0)
        var inner = MessageBuilder()
        inner.u32(UInt32(payload.count))
        inner.raw(payload)

        var out = MessageBuilder()
        out.u32(Flags([.provide, .text]).rawValue)
        out.raw(try deflater.compress(inner.bytes))
        return out.bytes
    }

    /// Extracts the text from a provide payload (everything after the flags).
    public static func textFromProvide(_ zlibData: [UInt8]) throws -> String? {
        let inflater = Inflater()
        let raw = try inflater.inflateAll(zlibData, hint: max(zlibData.count * 4, 1024))
        guard raw.count >= 4 else {
            throw RFBError.decode("clipboard payload is \(raw.count) bytes, need at least 4")
        }
        let declared = Int(UInt32(raw[0]) << 24 | UInt32(raw[1]) << 16
                           | UInt32(raw[2]) << 8 | UInt32(raw[3]))
        guard declared >= 1 else { return nil }
        guard raw.count >= 4 + declared else {
            throw RFBError.decode("clipboard says \(declared) bytes but only \(raw.count - 4) arrived")
        }
        // The declared length includes the NUL terminator; some senders omit it.
        var end = 4 + declared
        if raw[end - 1] == 0 { end -= 1 }
        guard end > 4 else { return nil }
        let body = Array(raw[4..<end])
        guard let text = String(bytes: body, encoding: .utf8) else {
            throw RFBError.decode("clipboard text is not valid UTF-8")
        }
        return crlfToLF(text)
    }

    /// The wire format uses CRLF line endings.
    public static func lfToCRLF(_ text: String) -> String {
        crlfToLF(text).replacingOccurrences(of: "\n", with: "\r\n")
    }

    public static func crlfToLF(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
    }
}
