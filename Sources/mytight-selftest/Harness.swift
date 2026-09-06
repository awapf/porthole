import Foundation
import CZlib
import MyTightCore

/// Tiny assertion harness. The Command Line Tools ship neither a usable XCTest
/// nor a complete swift-testing, so the suite is a plain executable instead of
/// a test target — it runs on any machine that can build the client.
final class Harness {
    private var failures: [String] = []
    private var passed = 0
    private var current = ""

    func test(_ name: String, _ body: () throws -> Void) {
        current = name
        do {
            try body()
            passed += 1
            print("  ok   \(name)")
        } catch {
            failures.append("\(name): threw \(error)")
            print("  FAIL \(name): threw \(error)")
        }
    }

    func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw HarnessError.failed(message()) }
    }

    func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ label: String = "") throws {
        if lhs != rhs {
            throw HarnessError.failed("\(label.isEmpty ? "" : label + ": ")expected \(rhs), got \(lhs)")
        }
    }

    func summarise() -> Int32 {
        print("")
        if failures.isEmpty {
            print("\(passed) passed")
            return 0
        }
        print("\(passed) passed, \(failures.count) FAILED")
        for failure in failures { print("  - \(failure)") }
        return 1
    }
}

enum HarnessError: Error, CustomStringConvertible {
    case failed(String)
    var description: String { if case .failed(let m) = self { return m }; return "failed" }
}

/// Deflate helper used to build the compressed halves of synthetic Tight and
/// ZRLE rectangles.
final class Deflater {
    private var stream = z_stream()

    init() { _ = deflateInit_(&stream, 6, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) }

    func compress(_ input: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: max(input.count * 2 + 128, 512))
        var produced = 0
        input.withUnsafeBufferPointer { inBuf in
            out.withUnsafeMutableBufferPointer { outBuf in
                stream.next_in = UnsafeMutablePointer(mutating: inBuf.baseAddress)
                stream.avail_in = uInt(inBuf.count)
                stream.next_out = outBuf.baseAddress
                stream.avail_out = uInt(outBuf.count)
                _ = CZlib.deflate(&stream, Z_SYNC_FLUSH)
                produced = outBuf.count - Int(stream.avail_out)
            }
        }
        out.removeLast(out.count - produced)
        return out
    }

    deinit { deflateEnd(&stream) }
}

/// Tight's 7-bits-per-byte length prefix.
func compactLength(_ value: Int) -> [UInt8] {
    var out: [UInt8] = []
    var v = value
    out.append(UInt8(v & 0x7F) | (v > 0x7F ? 0x80 : 0))
    v >>= 7
    if v > 0 {
        out.append(UInt8(v & 0x7F) | (v > 0x7F ? 0x80 : 0))
        v >>= 7
        if v > 0 { out.append(UInt8(v & 0xFF)) }
    }
    return out
}

func rgb(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> UInt32 { packBGRA(r: r, g: g, b: b) }
