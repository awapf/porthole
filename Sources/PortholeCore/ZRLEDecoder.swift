import Foundation

/// ZRLE (encoding 16) and TRLE (15). One persistent zlib stream carries a
/// raster-order sequence of 64x64 tiles; TRLE is the same tile format sent
/// uncompressed.
public final class ZRLEDecoder {
    private let inflater = Inflater()
    private static let tileSize = 64

    public init() {}

    public func reset() { inflater.reset() }

    public func decode(reader: BufferedReader, rect: RFBRect, into fb: Framebuffer,
                       pixelFormat pf: PixelFormat, compressed: Bool) throws {
        let length = Int(try reader.readU32())
        let payload = try reader.readBytes(length)
        let tiles = compressed
            ? try inflater.inflateAll(payload, hint: rect.width * rect.height * 4)
            : payload
        var cursor = ByteCursor(tiles)
        try decodeTiles(&cursor, rect: rect, into: fb, pixelFormat: pf)
    }

    private func decodeTiles(_ cursor: inout ByteCursor, rect: RFBRect, into fb: Framebuffer,
                             pixelFormat pf: PixelFormat) throws {
        let pixelSize = pf.usesCompactPixel ? 3 : pf.bytesPerPixel
        var tile = [UInt32](repeating: 0, count: Self.tileSize * Self.tileSize)

        var ty = rect.y
        while ty < rect.y + rect.height {
            let th = min(Self.tileSize, rect.y + rect.height - ty)
            var tx = rect.x
            while tx < rect.x + rect.width {
                let tw = min(Self.tileSize, rect.x + rect.width - tx)
                let subencoding = try cursor.u8()
                let paletteSize = Int(subencoding & 0x7F)
                let isRLE = subencoding & 0x80 != 0

                if !isRLE && paletteSize == 0 {
                    for i in 0..<(tw * th) { tile[i] = try cursor.pixel(pixelSize, pf) }
                } else if !isRLE && paletteSize == 1 {
                    let colour = try cursor.pixel(pixelSize, pf)
                    for i in 0..<(tw * th) { tile[i] = colour }
                } else if !isRLE {
                    try readPackedPalette(&cursor, into: &tile, tw: tw, th: th,
                                          paletteSize: paletteSize, pixelSize: pixelSize, pf: pf)
                } else if paletteSize == 0 {
                    try readPlainRLE(&cursor, into: &tile, count: tw * th, pixelSize: pixelSize, pf: pf)
                } else {
                    try readPaletteRLE(&cursor, into: &tile, count: tw * th,
                                       paletteSize: paletteSize, pixelSize: pixelSize, pf: pf)
                }

                for y in 0..<th {
                    let dst = fb.row(ty + y) + tx
                    tile.withUnsafeBufferPointer { src in
                        dst.update(from: src.baseAddress! + y * tw, count: tw)
                    }
                }
                tx += tw
            }
            ty += th
        }
    }

    private func readPackedPalette(_ cursor: inout ByteCursor, into tile: inout [UInt32],
                                   tw: Int, th: Int, paletteSize: Int, pixelSize: Int,
                                   pf: PixelFormat) throws {
        var palette = [UInt32]()
        palette.reserveCapacity(paletteSize)
        for _ in 0..<paletteSize { palette.append(try cursor.pixel(pixelSize, pf)) }

        let bits = paletteSize <= 2 ? 1 : (paletteSize <= 4 ? 2 : 4)
        let mask = UInt8((1 << bits) - 1)
        let rowBytes = (tw * bits + 7) / 8

        for y in 0..<th {
            let rowStart = cursor.offset
            for x in 0..<tw {
                let bitPos = x * bits
                let byte = try cursor.peek(at: rowStart + bitPos / 8)
                let shift = 8 - bits - (bitPos % 8)
                let index = Int((byte >> UInt8(shift)) & mask)
                tile[y * tw + x] = index < palette.count ? palette[index] : 0xFF00_0000
            }
            try cursor.advance(rowBytes)
        }
    }

    private func readPlainRLE(_ cursor: inout ByteCursor, into tile: inout [UInt32],
                              count: Int, pixelSize: Int, pf: PixelFormat) throws {
        var written = 0
        while written < count {
            let colour = try cursor.pixel(pixelSize, pf)
            let run = try cursor.runLength()
            let n = min(run, count - written)
            for i in 0..<n { tile[written + i] = colour }
            written += n
        }
    }

    private func readPaletteRLE(_ cursor: inout ByteCursor, into tile: inout [UInt32],
                                count: Int, paletteSize: Int, pixelSize: Int,
                                pf: PixelFormat) throws {
        var palette = [UInt32]()
        palette.reserveCapacity(paletteSize)
        for _ in 0..<paletteSize { palette.append(try cursor.pixel(pixelSize, pf)) }

        var written = 0
        while written < count {
            let byte = try cursor.u8()
            let index = Int(byte & 0x7F)
            let run = byte & 0x80 != 0 ? try cursor.runLength() : 1
            let colour = index < palette.count ? palette[index] : 0xFF00_0000
            let n = min(run, count - written)
            for i in 0..<n { tile[written + i] = colour }
            written += n
        }
    }
}

/// Cursor over an in-memory buffer, used for the inflated ZRLE tile stream.
struct ByteCursor {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func u8() throws -> UInt8 {
        guard offset < bytes.count else { throw RFBError.decode("ZRLE stream truncated") }
        defer { offset += 1 }
        return bytes[offset]
    }

    func peek(at index: Int) throws -> UInt8 {
        guard index < bytes.count else { throw RFBError.decode("ZRLE stream truncated") }
        return bytes[index]
    }

    mutating func advance(_ n: Int) throws {
        guard offset + n <= bytes.count else { throw RFBError.decode("ZRLE stream truncated") }
        offset += n
    }

    mutating func pixel(_ size: Int, _ pf: PixelFormat) throws -> UInt32 {
        guard offset + size <= bytes.count else { throw RFBError.decode("ZRLE stream truncated") }
        defer { offset += size }
        return bytes.withUnsafeBufferPointer { decodePixel($0.baseAddress! + offset, size, pf) }
    }

    /// Run length: 255-valued bytes accumulate, the final byte terminates, +1.
    mutating func runLength() throws -> Int {
        var total = 1
        while true {
            let byte = try u8()
            total += Int(byte)
            if byte != 255 { return total }
        }
    }
}
