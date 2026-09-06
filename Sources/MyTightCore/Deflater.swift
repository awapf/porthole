import Foundation
import CZlib

/// One-shot zlib compression. The extended clipboard starts a fresh stream per
/// message, so this deliberately does not persist history the way `Inflater`
/// does for Tight and ZRLE.
public final class Deflater {
    public init() {}

    public func compress(_ input: [UInt8], level: Int32 = 6) throws -> [UInt8] {
        var stream = z_stream()
        guard deflateInit_(&stream, level, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw RFBError.decode("deflateInit failed")
        }
        defer { deflateEnd(&stream) }

        var out = [UInt8](repeating: 0, count: max(input.count + input.count / 2 + 128, 256))
        var produced = 0
        var result: Int32 = Z_OK
        input.withUnsafeBufferPointer { inBuf in
            out.withUnsafeMutableBufferPointer { outBuf in
                stream.next_in = UnsafeMutablePointer(mutating: inBuf.baseAddress)
                stream.avail_in = uInt(inBuf.count)
                stream.next_out = outBuf.baseAddress
                stream.avail_out = uInt(outBuf.count)
                result = deflate(&stream, Z_FINISH)
                produced = outBuf.count - Int(stream.avail_out)
            }
            stream.next_in = nil
            stream.next_out = nil
        }
        guard result == Z_STREAM_END else { throw RFBError.decode("deflate failed (\(result))") }
        out.removeLast(out.count - produced)
        return out
    }
}
