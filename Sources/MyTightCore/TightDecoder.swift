import Foundation
import ImageIO
import CoreGraphics

/// Tight (encoding 7).
///
/// wayvnc/neatvnc only ever emits the BASIC and JPEG subtypes, but TigerVNC and
/// x11vnc use FILL, palette and gradient too, so all of them are handled here.
public final class TightDecoder {
    /// Four independent zlib streams whose history the server resets explicitly.
    private var streams = [Inflater(), Inflater(), Inflater(), Inflater()]
    private var scratch = [UInt8]()

    /// Below this many bytes the server skips zlib entirely.
    private static let minToCompress = 12

    public init() {}

    public func reset() { streams = [Inflater(), Inflater(), Inflater(), Inflater()] }

    public func decode(reader: BufferedReader, rect: RFBRect, into fb: Framebuffer,
                       pixelFormat pf: PixelFormat) throws {
        let control = try reader.readU8()
        for i in 0..<4 where control & (1 << i) != 0 {
            streams[i].reset()
        }

        switch control >> 4 {
        case 0x08:
            let colour = try readTPixel(reader, pf)
            fb.fill(rect, with: colour)
        case 0x09:
            try decodeJPEG(reader: reader, rect: rect, into: fb)
        case 0x0A:
            throw RFBError.decode("TightPNG is not supported")
        default:
            try decodeBasic(control: control, reader: reader, rect: rect, into: fb, pixelFormat: pf)
        }
    }

    // MARK: - Basic compression

    private enum Filter: UInt8 { case copy = 0, palette = 1, gradient = 2 }

    private func decodeBasic(control: UInt8, reader: BufferedReader, rect: RFBRect,
                             into fb: Framebuffer, pixelFormat pf: PixelFormat) throws {
        let streamID = Int((control >> 4) & 0x03)
        var filter = Filter.copy
        if control & 0x40 != 0 {
            guard let f = Filter(rawValue: try reader.readU8()) else {
                throw RFBError.decode("unknown Tight filter")
            }
            filter = f
        }

        let pixelSize = pf.usesCompactPixel ? 3 : pf.bytesPerPixel
        var palette: [UInt32] = []
        var rowBytes = 0

        switch filter {
        case .copy, .gradient:
            rowBytes = rect.width * pixelSize
        case .palette:
            let count = Int(try reader.readU8()) + 1
            palette.reserveCapacity(count)
            for _ in 0..<count { palette.append(try readTPixel(reader, pf)) }
            rowBytes = count <= 2 ? (rect.width + 7) / 8 : rect.width
        }

        let total = rowBytes * rect.height
        guard total > 0 else { return }

        if scratch.count < total { scratch = [UInt8](repeating: 0, count: total) }

        if total < Self.minToCompress {
            try scratch.withUnsafeMutableBytes { try reader.readRaw(into: $0.baseAddress!, count: total) }
        } else {
            let compressedLength = try readCompactLength(reader)
            let payload = try reader.readBytes(compressedLength)
            try scratch.withUnsafeMutableBytes {
                try streams[streamID].inflate(payload, into: $0.baseAddress!, outputCount: total)
            }
        }

        switch filter {
        case .copy:
            blitPixels(rect: rect, into: fb, pixelSize: pixelSize, pixelFormat: pf)
        case .palette:
            blitPalette(rect: rect, into: fb, palette: palette, rowBytes: rowBytes)
        case .gradient:
            blitGradient(rect: rect, into: fb, pixelSize: pixelSize, pixelFormat: pf)
        }
    }

    private func blitPixels(rect: RFBRect, into fb: Framebuffer, pixelSize: Int, pixelFormat pf: PixelFormat) {
        scratch.withUnsafeBytes { src in
            let base = src.baseAddress!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<rect.height {
                let dst = fb.row(rect.y + y) + rect.x
                let line = base + y * rect.width * pixelSize
                for x in 0..<rect.width {
                    dst[x] = decodePixel(line + x * pixelSize, pixelSize, pf)
                }
            }
        }
    }

    private func blitPalette(rect: RFBRect, into fb: Framebuffer, palette: [UInt32], rowBytes: Int) {
        scratch.withUnsafeBytes { src in
            let base = src.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let oneBit = palette.count <= 2
            for y in 0..<rect.height {
                let dst = fb.row(rect.y + y) + rect.x
                let line = base + y * rowBytes
                if oneBit {
                    for x in 0..<rect.width {
                        let bit = (line[x / 8] >> (7 - UInt8(x % 8))) & 1
                        dst[x] = palette[Int(bit)]
                    }
                } else {
                    for x in 0..<rect.width {
                        let index = Int(line[x])
                        dst[x] = index < palette.count ? palette[index] : 0xFF00_0000
                    }
                }
            }
        }
    }

    /// Gradient filter: each channel is a delta against `left + up - upleft`.
    private func blitGradient(rect: RFBRect, into fb: Framebuffer, pixelSize: Int, pixelFormat pf: PixelFormat) {
        var previous = [Int](repeating: 0, count: (rect.width + 1) * 3)
        var current = [Int](repeating: 0, count: (rect.width + 1) * 3)

        scratch.withUnsafeBytes { src in
            let base = src.baseAddress!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<rect.height {
                let line = base + y * rect.width * pixelSize
                let dst = fb.row(rect.y + y) + rect.x
                for x in 0..<rect.width {
                    let sample = line + x * pixelSize
                    var rgb = [Int](repeating: 0, count: 3)
                    for c in 0..<3 {
                        let left = current[x * 3 + c]
                        let up = previous[(x + 1) * 3 + c]
                        let upLeft = previous[x * 3 + c]
                        var prediction = left + up - upLeft
                        if prediction < 0 { prediction = 0 }
                        if prediction > 255 { prediction = 255 }
                        let value = (Int(sample[c]) + prediction) & 0xFF
                        current[(x + 1) * 3 + c] = value
                        rgb[c] = value
                    }
                    dst[x] = packBGRA(r: UInt8(rgb[0]), g: UInt8(rgb[1]), b: UInt8(rgb[2]))
                }
                swap(&previous, &current)
                for i in 0..<3 { current[i] = 0 }
            }
        }
    }

    // MARK: - JPEG

    private func decodeJPEG(reader: BufferedReader, rect: RFBRect, into fb: Framebuffer) throws {
        let length = try readCompactLength(reader)
        let data = Data(try reader.readBytes(length))
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw RFBError.decode("JPEG tile could not be decoded")
        }
        guard rect.x >= 0, rect.y >= 0,
              rect.x + rect.width <= fb.width, rect.y + rect.height <= fb.height else {
            throw RFBError.decode("JPEG rect outside framebuffer")
        }

        // Render straight into the framebuffer sub-rect: same BGRA layout, so
        // no intermediate buffer or repack is needed.
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        guard let ctx = CGContext(data: fb.row(rect.y) + rect.x,
                                  width: rect.width,
                                  height: rect.height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: fb.rowStride * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: bitmapInfo) else {
            throw RFBError.decode("could not wrap framebuffer in a CGContext")
        }
        // No flip: a bitmap context whose buffer starts at the top-left already
        // draws images the right way up, which is exactly our layout.
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
    }

    // MARK: - Primitives

    /// Tight length prefix: 7 bits per byte, high bit continues.
    private func readCompactLength(_ reader: BufferedReader) throws -> Int {
        var byte = try reader.readU8()
        var length = Int(byte & 0x7F)
        if byte & 0x80 != 0 {
            byte = try reader.readU8()
            length |= Int(byte & 0x7F) << 7
            if byte & 0x80 != 0 {
                byte = try reader.readU8()
                length |= Int(byte & 0xFF) << 14
            }
        }
        return length
    }

    private func readTPixel(_ reader: BufferedReader, _ pf: PixelFormat) throws -> UInt32 {
        if pf.usesCompactPixel {
            let b = try reader.readBytes(3)
            return packBGRA(r: b[0], g: b[1], b: b[2])
        }
        let b = try reader.readBytes(pf.bytesPerPixel)
        return b.withUnsafeBufferPointer { decodePixel($0.baseAddress!, pf.bytesPerPixel, pf) }
    }
}

/// Converts one wire pixel to little-endian BGRA.
@inline(__always)
public func decodePixel(_ src: UnsafePointer<UInt8>, _ size: Int, _ pf: PixelFormat) -> UInt32 {
    if size == 3 {
        // Compact TPIXEL/CPIXEL is always R,G,B in significance order.
        return packBGRA(r: src[0], g: src[1], b: src[2])
    }
    var raw: UInt32 = 0
    if pf.bigEndian {
        for i in 0..<size { raw = (raw << 8) | UInt32(src[i]) }
    } else {
        for i in stride(from: size - 1, through: 0, by: -1) { raw = (raw << 8) | UInt32(src[i]) }
    }
    let r = UInt8((raw >> UInt32(pf.redShift)) & UInt32(pf.redMax))
    let g = UInt8((raw >> UInt32(pf.greenShift)) & UInt32(pf.greenMax))
    let b = UInt8((raw >> UInt32(pf.blueShift)) & UInt32(pf.blueMax))
    return packBGRA(r: r, g: g, b: b)
}
