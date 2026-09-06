import Foundation

public enum SocketError: Error, CustomStringConvertible {
    case resolve(String)
    case connect(String)
    case closed
    case io(String)

    public var description: String {
        switch self {
        case .resolve(let s): return "cannot resolve \(s)"
        case .connect(let s): return "connection failed: \(s)"
        case .closed: return "connection closed by peer"
        case .io(let s): return "socket error: \(s)"
        }
    }
}

/// Anything the `BufferedReader` can pull bytes from. Sockets in production,
/// an in-memory buffer when exercising the decoders.
public protocol ByteSource: AnyObject {
    /// Returns the number of bytes read; 0 means end of stream.
    func read(into buffer: UnsafeMutableRawPointer, count: Int) throws -> Int
}

/// The outbound half. Splitting it from `ByteSource` lets the handshake be
/// driven against an in-memory peer in the self-test.
public protocol ByteSink: AnyObject {
    func write(_ bytes: [UInt8]) throws
    func close()
}

public typealias Transport = ByteSource & ByteSink

/// Blocking TCP socket. The RFB session runs on its own thread, so blocking
/// reads keep the protocol parser linear and free of continuation plumbing.
public final class Socket: Transport {
    private var fd: Int32 = -1
    private let writeLock = NSLock()
    private var isClosed = false

    public init(host: String, port: UInt16, timeout: TimeInterval = 15) throws {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &res)
        guard rc == 0, let list = res else {
            throw SocketError.resolve("\(host): \(String(cString: gai_strerror(rc)))")
        }
        defer { freeaddrinfo(list) }

        var lastError = "no address"
        var candidate: UnsafeMutablePointer<addrinfo>? = list
        while let info = candidate {
            let s = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if s >= 0 {
                var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
                setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                if Foundation.connect(s, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 {
                    // Latency beats throughput for interactive input echo.
                    var one: Int32 = 1
                    setsockopt(s, Int32(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
                    setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                    // Clear the send timeout now that we are connected.
                    var zero = timeval(tv_sec: 0, tv_usec: 0)
                    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &zero, socklen_t(MemoryLayout<timeval>.size))
                    fd = s
                    return
                }
                lastError = String(cString: strerror(errno))
                Foundation.close(s)
            } else {
                lastError = String(cString: strerror(errno))
            }
            candidate = info.pointee.ai_next
        }
        throw SocketError.connect("\(host):\(port): \(lastError)")
    }

    /// Reads into `buffer`, returning the number of bytes read. 0 means EOF.
    public func read(into buffer: UnsafeMutableRawPointer, count: Int) throws -> Int {
        while true {
            let n = Foundation.read(fd, buffer, count)
            if n >= 0 { return n }
            if errno == EINTR { continue }
            if isClosed { throw SocketError.closed }
            throw SocketError.io(String(cString: strerror(errno)))
        }
    }

    public func write(_ bytes: [UInt8]) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard fd >= 0 else { throw SocketError.closed }
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Foundation.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n > 0 { offset += n; continue }
                if n < 0 && errno == EINTR { continue }
                throw SocketError.io(n == 0 ? "short write" : String(cString: strerror(errno)))
            }
        }
    }

    public func close() {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard fd >= 0, !isClosed else { return }
        isClosed = true
        shutdown(fd, SHUT_RDWR)
        Foundation.close(fd)
        fd = -1
    }

    deinit { close() }
}

/// Buffered reader guaranteeing exact-length reads.
public final class BufferedReader {
    private let source: ByteSource
    private var buffer: [UInt8]
    private var start = 0
    private var end = 0

    /// Total bytes pulled off the wire, for the bandwidth readout.
    public private(set) var bytesRead: UInt64 = 0

    public init(source: ByteSource, capacity: Int = 1 << 18) {
        self.source = source
        self.buffer = [UInt8](repeating: 0, count: capacity)
    }

    private func refill() throws {
        if start == end { start = 0; end = 0 }
        if end == buffer.count {
            if start > 0 {
                buffer.withUnsafeMutableBytes { raw in
                    let base = raw.baseAddress!
                    memmove(base, base.advanced(by: start), end - start)
                }
                end -= start
                start = 0
            }
        }
        // `raw.count`, not `buffer.count`: touching the array while it is
        // exclusively borrowed here is an access conflict.
        let tail = end
        let n = try buffer.withUnsafeMutableBytes { raw -> Int in
            try source.read(into: raw.baseAddress!.advanced(by: tail), count: raw.count - tail)
        }
        if n == 0 { throw SocketError.closed }
        end += n
        bytesRead &+= UInt64(n)
    }

    public func readBytes(_ count: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        try out.withUnsafeMutableBytes { raw in
            try readRaw(into: raw.baseAddress!, count: count)
        }
        return out
    }

    /// Reads exactly `count` bytes straight into caller memory — used by the
    /// decoders to land pixels in the framebuffer without an intermediate copy.
    public func readRaw(into dest: UnsafeMutableRawPointer, count: Int) throws {
        var written = 0
        while written < count {
            if start == end { try refill() }
            let chunk = min(end - start, count - written)
            buffer.withUnsafeBytes { raw in
                memcpy(dest.advanced(by: written), raw.baseAddress!.advanced(by: start), chunk)
            }
            start += chunk
            written += chunk
        }
    }

    public func readU8() throws -> UInt8 {
        if start == end { try refill() }
        let v = buffer[start]
        start += 1
        return v
    }

    public func readU16() throws -> UInt16 {
        let b = try readBytes(2)
        return UInt16(b[0]) << 8 | UInt16(b[1])
    }

    public func readU32() throws -> UInt32 {
        let b = try readBytes(4)
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }

    public func readS32() throws -> Int32 {
        Int32(bitPattern: try readU32())
    }

    public func skip(_ count: Int) throws {
        var remaining = count
        while remaining > 0 {
            if start == end { try refill() }
            let chunk = min(end - start, remaining)
            start += chunk
            remaining -= chunk
        }
    }
}


/// In-memory `ByteSource`, used to drive the decoders from synthetic server
/// output without opening a connection.
public final class MemoryByteSource: ByteSource {
    private let bytes: [UInt8]
    private var offset = 0

    public init(_ bytes: [UInt8]) { self.bytes = bytes }

    public func read(into buffer: UnsafeMutableRawPointer, count: Int) throws -> Int {
        let n = min(count, bytes.count - offset)
        guard n > 0 else { return 0 }
        bytes.withUnsafeBytes { memcpy(buffer, $0.baseAddress!.advanced(by: offset), n) }
        offset += n
        return n
    }
}
