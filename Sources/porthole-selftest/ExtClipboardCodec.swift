import Foundation
import PortholeCore

/// Decodes a provide payload the way neatvnc does, independently of the
/// client's own codec, so the test is not just checking the encoder against
/// itself.
enum ExtClipboardTestCodec {
    static func text(fromProvide body: [UInt8]) throws -> String {
        let inflater = Inflater()
        let raw = try inflater.inflateAll(body, hint: 4096)
        guard raw.count >= 4 else { throw HarnessError.failed("provide payload too short") }
        let declared = Int(UInt32(raw[0]) << 24 | UInt32(raw[1]) << 16
                           | UInt32(raw[2]) << 8 | UInt32(raw[3]))
        guard declared >= 1, raw.count >= 4 + declared else {
            throw HarnessError.failed("provide length mismatch")
        }
        // neatvnc rejects the message unless the last byte is a NUL.
        guard raw[4 + declared - 1] == 0 else {
            throw HarnessError.failed("provide text is not NUL terminated")
        }
        let bytes = Array(raw[4..<(4 + declared - 1)])
        guard let text = String(bytes: bytes, encoding: .utf8) else {
            throw HarnessError.failed("provide text is not valid UTF-8")
        }
        // neatvnc runs crlf_to_lf on what it receives; mirror that so the
        // comparison is against what the compositor would actually paste.
        return text.replacingOccurrences(of: "\r\n", with: "\n")
    }

    /// Builds a provide payload as neatvnc would send one.
    static func provide(text: String) throws -> [UInt8] {
        var payload = [UInt8](text.replacingOccurrences(of: "\n", with: "\r\n").utf8)
        payload.append(0)
        var inner: [UInt8] = []
        let n = UInt32(payload.count)
        inner += [UInt8(n >> 24 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)]
        inner += payload
        return try Deflater().compress(inner)
    }
}
