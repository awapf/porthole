import Foundation
import CZlib

/// A zlib inflate stream whose sliding-window history persists across calls.
/// Tight keeps four of these; ZRLE keeps one. Resetting must be explicit,
/// driven by the server's reset bits — never implicit per message.
public final class Inflater {
    private var stream = z_stream()
    private var initialised = false

    public init() { try? start() }

    private func start() throws {
        let rc = inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard rc == Z_OK else { throw RFBError.decode("inflateInit failed (\(rc))") }
        initialised = true
    }

    public func reset() {
        guard initialised else { return }
        inflateReset(&stream)
    }

    /// Inflates `input` producing exactly `outputCount` bytes into `dest`.
    public func inflate(_ input: [UInt8], into dest: UnsafeMutableRawPointer, outputCount: Int) throws {
        guard initialised else { throw RFBError.decode("inflater not initialised") }
        if outputCount == 0 { return }
        var result: Int32 = Z_OK
        input.withUnsafeBufferPointer { inBuf in
            stream.next_in = UnsafeMutablePointer(mutating: inBuf.baseAddress)
            stream.avail_in = uInt(inBuf.count)
            stream.next_out = dest.assumingMemoryBound(to: UInt8.self)
            stream.avail_out = uInt(outputCount)
            result = CZlib.inflate(&stream, Z_SYNC_FLUSH)
            stream.next_in = nil
            stream.next_out = nil
        }
        guard result == Z_OK || result == Z_STREAM_END else {
            throw RFBError.decode("inflate failed (\(result))")
        }
        guard stream.avail_out == 0 else {
            throw RFBError.decode("inflate produced \(outputCount - Int(stream.avail_out)) of \(outputCount) bytes")
        }
    }

    /// Inflates all of `input`, growing the output as needed. Used by ZRLE,
    /// whose uncompressed tile stream has no length prefix.
    public func inflateAll(_ input: [UInt8], hint: Int) throws -> [UInt8] {
        guard initialised else { throw RFBError.decode("inflater not initialised") }
        var out = [UInt8](repeating: 0, count: max(hint, 1024))
        var produced = 0
        var finished = false

        try input.withUnsafeBufferPointer { inBuf in
            stream.next_in = UnsafeMutablePointer(mutating: inBuf.baseAddress)
            stream.avail_in = uInt(inBuf.count)
            defer { stream.next_in = nil; stream.next_out = nil }

            while !finished {
                if produced == out.count { out.append(contentsOf: [UInt8](repeating: 0, count: out.count)) }
                var rc: Int32 = Z_OK
                out.withUnsafeMutableBufferPointer { outBuf in
                    stream.next_out = outBuf.baseAddress!.advanced(by: produced)
                    stream.avail_out = uInt(outBuf.count - produced)
                    rc = CZlib.inflate(&stream, Z_SYNC_FLUSH)
                    produced = outBuf.count - Int(stream.avail_out)
                }
                guard rc == Z_OK || rc == Z_STREAM_END || rc == Z_BUF_ERROR else {
                    throw RFBError.decode("inflate failed (\(rc))")
                }
                // All input consumed and the last pass could not fill the
                // output buffer: the stream has yielded everything it has.
                if stream.avail_in == 0 && (rc == Z_BUF_ERROR || stream.avail_out > 0) { finished = true }
            }
        }
        out.removeLast(out.count - produced)
        return out
    }

    deinit {
        if initialised { inflateEnd(&stream) }
    }
}
