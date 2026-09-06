import Foundation
import PortholeCore

/// Builds synthetic Tight rectangles the way neatvnc/TigerVNC would, then
/// checks the decoder reproduces the source image exactly. These round trips
/// are the only practical way to catch bit-level mistakes in the filters.
enum TightFixture {

    /// Tight FILL: one solid colour, no compression involved.
    static func fill(r: UInt8, g: UInt8, b: UInt8) -> [UInt8] {
        [0x80, r, g, b]
    }

    /// Tight BASIC with the copy filter: raw RGB triples, zlib'd through the
    /// nominated stream. `reset` sets the stream's reset bit.
    static func basicCopy(image: [[(UInt8, UInt8, UInt8)]], stream: Int,
                          deflater: Deflater, reset: Bool) -> [UInt8] {
        var raw: [UInt8] = []
        for row in image { for px in row { raw += [px.0, px.1, px.2] } }
        var out: [UInt8] = [UInt8((stream << 4) | (reset ? (1 << stream) : 0))]
        out += payload(raw, deflater: deflater)
        return out
    }

    /// Tight BASIC with the palette filter. Two colours pack to one bit per
    /// pixel, MSB first, each row padded to a byte.
    static func basicPalette(indices: [[Int]], palette: [(UInt8, UInt8, UInt8)],
                             deflater: Deflater) -> [UInt8] {
        var out: [UInt8] = [0x41]          // stream 0, explicit filter, reset stream 0
        out.append(0x01)                    // filter: palette
        out.append(UInt8(palette.count - 1))
        for colour in palette { out += [colour.0, colour.1, colour.2] }

        var raw: [UInt8] = []
        let width = indices[0].count
        if palette.count <= 2 {
            let rowBytes = (width + 7) / 8
            for row in indices {
                var line = [UInt8](repeating: 0, count: rowBytes)
                for (x, index) in row.enumerated() where index != 0 {
                    line[x / 8] |= 1 << (7 - UInt8(x % 8))
                }
                raw += line
            }
        } else {
            for row in indices { raw += row.map { UInt8($0) } }
        }
        out += payload(raw, deflater: deflater)
        return out
    }

    /// Tight BASIC with the gradient filter: each channel is stored as a delta
    /// against `clamp(left + up - upLeft)`.
    static func basicGradient(image: [[(UInt8, UInt8, UInt8)]], deflater: Deflater) -> [UInt8] {
        var out: [UInt8] = [0x41]          // stream 0, explicit filter, reset stream 0
        out.append(0x02)                    // filter: gradient

        let height = image.count, width = image[0].count
        var previous = [Int](repeating: 0, count: (width + 1) * 3)
        var current = [Int](repeating: 0, count: (width + 1) * 3)
        var raw: [UInt8] = []

        for y in 0..<height {
            for x in 0..<width {
                let px = image[y][x]
                let channels = [px.0, px.1, px.2]
                for c in 0..<3 {
                    let left = current[x * 3 + c]
                    let up = previous[(x + 1) * 3 + c]
                    let upLeft = previous[x * 3 + c]
                    var prediction = left + up - upLeft
                    if prediction < 0 { prediction = 0 }
                    if prediction > 255 { prediction = 255 }
                    let actual = Int(channels[c])
                    raw.append(UInt8((actual - prediction) & 0xFF))
                    current[(x + 1) * 3 + c] = actual
                }
            }
            swap(&previous, &current)
            for i in 0..<3 { current[i] = 0 }
        }
        out += payload(raw, deflater: deflater)
        return out
    }

    /// Under 12 bytes the server skips zlib entirely; above it, a compact
    /// length prefix precedes the deflated block.
    private static func payload(_ raw: [UInt8], deflater: Deflater) -> [UInt8] {
        if raw.count < 12 { return raw }
        let compressed = deflater.compress(raw)
        return compactLength(compressed.count) + compressed
    }
}

/// Builds ZRLE rectangles: a length-prefixed zlib stream of 64x64 tiles.
enum ZRLEFixture {
    static func rect(tiles: [[UInt8]], deflater: Deflater) -> [UInt8] {
        let stream = tiles.flatMap { $0 }
        let compressed = deflater.compress(stream)
        var out: [UInt8] = []
        let length = UInt32(compressed.count)
        out += [UInt8(length >> 24), UInt8((length >> 16) & 0xff),
                UInt8((length >> 8) & 0xff), UInt8(length & 0xff)]
        out += compressed
        return out
    }

    static func rawTile(_ pixels: [(UInt8, UInt8, UInt8)]) -> [UInt8] {
        var tile: [UInt8] = [0]
        for px in pixels { tile += [px.0, px.1, px.2] }
        return tile
    }

    static func solidTile(_ colour: (UInt8, UInt8, UInt8)) -> [UInt8] {
        [1, colour.0, colour.1, colour.2]
    }

    /// Packed palette tile: 1, 2 or 4 bits per index, rows byte-aligned.
    static func packedPaletteTile(indices: [[Int]], palette: [(UInt8, UInt8, UInt8)]) -> [UInt8] {
        var tile: [UInt8] = [UInt8(palette.count)]
        for colour in palette { tile += [colour.0, colour.1, colour.2] }
        let bits = palette.count <= 2 ? 1 : (palette.count <= 4 ? 2 : 4)
        let width = indices[0].count
        let rowBytes = (width * bits + 7) / 8
        for row in indices {
            var line = [UInt8](repeating: 0, count: rowBytes)
            for (x, index) in row.enumerated() {
                let bitPos = x * bits
                let shift = 8 - bits - (bitPos % 8)
                line[bitPos / 8] |= UInt8(index) << UInt8(shift)
            }
            tile += line
        }
        return tile
    }

    /// Plain RLE: colour followed by a run length encoded as 255-chains.
    static func plainRLETile(runs: [((UInt8, UInt8, UInt8), Int)]) -> [UInt8] {
        var tile: [UInt8] = [128]
        for (colour, length) in runs {
            tile += [colour.0, colour.1, colour.2]
            tile += runLength(length)
        }
        return tile
    }

    /// Palette RLE: index byte, high bit set when a run length follows.
    static func paletteRLETile(palette: [(UInt8, UInt8, UInt8)],
                               runs: [(Int, Int)]) -> [UInt8] {
        var tile: [UInt8] = [UInt8(128 + palette.count)]
        for colour in palette { tile += [colour.0, colour.1, colour.2] }
        for (index, length) in runs {
            if length == 1 {
                tile.append(UInt8(index))
            } else {
                tile.append(UInt8(index) | 0x80)
                tile += runLength(length)
            }
        }
        return tile
    }

    private static func runLength(_ length: Int) -> [UInt8] {
        var remaining = length - 1
        var out: [UInt8] = []
        while remaining >= 255 { out.append(255); remaining -= 255 }
        out.append(UInt8(remaining))
        return out
    }
}
