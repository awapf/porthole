import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import PortholeCore

private func decodeTight(_ bytes: [UInt8], rect: RFBRect, into fb: Framebuffer,
                         using decoder: TightDecoder) throws {
    let reader = BufferedReader(source: MemoryByteSource(bytes))
    try decoder.decode(reader: reader, rect: rect, into: fb, pixelFormat: .bgra)
}

private func decodeZRLE(_ bytes: [UInt8], rect: RFBRect, into fb: Framebuffer,
                        using decoder: ZRLEDecoder) throws {
    let reader = BufferedReader(source: MemoryByteSource(bytes))
    try decoder.decode(reader: reader, rect: rect, into: fb, pixelFormat: .bgra, compressed: true)
}

/// A deterministic test image; every pixel differs so a transposed or
/// off-by-one blit cannot pass by accident.
private func testImage(width: Int, height: Int) -> [[(UInt8, UInt8, UInt8)]] {
    var rows: [[(UInt8, UInt8, UInt8)]] = []
    rows.reserveCapacity(height)
    for y in 0..<height {
        var row: [(UInt8, UInt8, UInt8)] = []
        row.reserveCapacity(width)
        for x in 0..<width {
            let r = UInt8((x * 7 + y * 13) & 0xFF)
            let g = UInt8((x * 3 + y * 29) & 0xFF)
            let b = UInt8((x * 11 + y * 5) & 0xFF)
            row.append((r, g, b))
        }
        rows.append(row)
    }
    return rows
}

private func assertMatches(_ fb: Framebuffer, _ image: [[(UInt8, UInt8, UInt8)]],
                           at rect: RFBRect, _ h: Harness, tolerance: Int = 0) throws {
    for y in 0..<image.count {
        for x in 0..<image[y].count {
            let actual = fb.row(rect.y + y)[rect.x + x]
            let expected = rgb(image[y][x].0, image[y][x].1, image[y][x].2)
            if tolerance == 0 {
                if actual != expected {
                    throw HarnessError.failed(String(format: "pixel (%d,%d): got %08X want %08X",
                                                     x, y, actual, expected))
                }
            } else {
                for shift in [0, 8, 16] {
                    let a = Int((actual >> UInt32(shift)) & 0xFF)
                    let e = Int((expected >> UInt32(shift)) & 0xFF)
                    if abs(a - e) > tolerance {
                        throw HarnessError.failed("pixel (\(x),\(y)) channel \(shift): \(a) vs \(e)")
                    }
                }
            }
        }
    }
}

func runDecoderTests(_ h: Harness) {

    print("tight")

    h.test("FILL paints a solid rect") {
        let fb = Framebuffer(width: 16, height: 16)
        let rect = RFBRect(x: 2, y: 3, width: 8, height: 5)
        try decodeTight(TightFixture.fill(r: 0x12, g: 0x34, b: 0x56),
                        rect: rect, into: fb, using: TightDecoder())
        try h.expectEqual(fb.row(3)[2], rgb(0x12, 0x34, 0x56), "inside")
        try h.expectEqual(fb.row(7)[9], rgb(0x12, 0x34, 0x56), "inside far corner")
        try h.expect(fb.row(8)[2] != rgb(0x12, 0x34, 0x56), "must not paint past the rect")
    }

    h.test("BASIC copy filter round-trips an image") {
        let image = testImage(width: 16, height: 12)
        let fb = Framebuffer(width: 32, height: 32)
        let rect = RFBRect(x: 4, y: 6, width: 16, height: 12)
        let bytes = TightFixture.basicCopy(image: image, stream: 0,
                                           deflater: Deflater(), reset: true)
        try decodeTight(bytes, rect: rect, into: fb, using: TightDecoder())
        try assertMatches(fb, image, at: rect, h)
    }

    h.test("BASIC copy below the compression threshold is sent raw") {
        // 2x1 pixels is 6 bytes, under Tight's 12-byte minimum, so no zlib.
        let image: [[(UInt8, UInt8, UInt8)]] = [[(1, 2, 3), (4, 5, 6)]]
        let fb = Framebuffer(width: 4, height: 4)
        let rect = RFBRect(x: 0, y: 0, width: 2, height: 1)
        let bytes = TightFixture.basicCopy(image: image, stream: 0,
                                           deflater: Deflater(), reset: true)
        try h.expectEqual(bytes.count, 7, "control byte plus six raw bytes")
        try decodeTight(bytes, rect: rect, into: fb, using: TightDecoder())
        try assertMatches(fb, image, at: rect, h)
    }

    h.test("a zlib stream keeps its history across rects") {
        // The decisive case: the second rect is deflated against the first
        // rect's history and carries no reset bit. A decoder that recreated the
        // stream per message would produce garbage here.
        let decoder = TightDecoder()
        let deflater = Deflater()
        let fb = Framebuffer(width: 64, height: 64)
        let first = testImage(width: 16, height: 8)
        let second = testImage(width: 16, height: 8).reversed().map { $0 }

        let rectA = RFBRect(x: 0, y: 0, width: 16, height: 8)
        try decodeTight(TightFixture.basicCopy(image: first, stream: 0,
                                               deflater: deflater, reset: true),
                        rect: rectA, into: fb, using: decoder)
        let rectB = RFBRect(x: 0, y: 16, width: 16, height: 8)
        try decodeTight(TightFixture.basicCopy(image: second, stream: 0,
                                               deflater: deflater, reset: false),
                        rect: rectB, into: fb, using: decoder)
        try assertMatches(fb, first, at: rectA, h)
        try assertMatches(fb, second, at: rectB, h)
    }

    h.test("the four zlib streams stay independent") {
        let decoder = TightDecoder()
        let deflaters = [Deflater(), Deflater(), Deflater(), Deflater()]
        let fb = Framebuffer(width: 64, height: 64)
        // Prime every stream, then reuse each without a reset in a different
        // order; cross-talk between streams would corrupt the later rects.
        var images: [[[(UInt8, UInt8, UInt8)]]] = []
        for s in 0..<4 {
            let image = testImage(width: 8, height: 8).map { row in
                row.map { (UInt8(($0.0 &+ UInt8(s * 40))), $0.1, $0.2) }
            }
            images.append(image)
            let rect = RFBRect(x: 0, y: s * 8, width: 8, height: 8)
            try decodeTight(TightFixture.basicCopy(image: image, stream: s,
                                                   deflater: deflaters[s], reset: true),
                            rect: rect, into: fb, using: decoder)
        }
        for s in [3, 1, 2, 0] {
            let rect = RFBRect(x: 16, y: s * 8, width: 8, height: 8)
            try decodeTight(TightFixture.basicCopy(image: images[s], stream: s,
                                                   deflater: deflaters[s], reset: false),
                            rect: rect, into: fb, using: decoder)
            try assertMatches(fb, images[s], at: rect, h)
        }
    }

    h.test("palette filter with two colours packs to one bit") {
        let palette: [(UInt8, UInt8, UInt8)] = [(0, 0, 0), (255, 255, 255)]
        let indices = (0..<10).map { y in (0..<13).map { x in (x + y) % 2 } }
        let fb = Framebuffer(width: 32, height: 32)
        let rect = RFBRect(x: 1, y: 1, width: 13, height: 10)
        try decodeTight(TightFixture.basicPalette(indices: indices, palette: palette,
                                                  deflater: Deflater()),
                        rect: rect, into: fb, using: TightDecoder())
        let expected = indices.map { row in row.map { palette[$0] } }
        try assertMatches(fb, expected, at: rect, h)
    }

    h.test("palette filter with many colours uses byte indices") {
        var palette: [(UInt8, UInt8, UInt8)] = []
        for i in 0..<7 {
            palette.append((UInt8(i * 30), UInt8(255 - i * 20), UInt8(i * 11)))
        }
        let indices = (0..<9).map { y in (0..<11).map { x in (x * 3 + y) % palette.count } }
        let fb = Framebuffer(width: 32, height: 32)
        let rect = RFBRect(x: 0, y: 0, width: 11, height: 9)
        try decodeTight(TightFixture.basicPalette(indices: indices, palette: palette,
                                                  deflater: Deflater()),
                        rect: rect, into: fb, using: TightDecoder())
        let expected = indices.map { row in row.map { palette[$0] } }
        try assertMatches(fb, expected, at: rect, h)
    }

    h.test("gradient filter reconstructs the prediction") {
        let image = testImage(width: 12, height: 9)
        let fb = Framebuffer(width: 32, height: 32)
        let rect = RFBRect(x: 3, y: 2, width: 12, height: 9)
        try decodeTight(TightFixture.basicGradient(image: image, deflater: Deflater()),
                        rect: rect, into: fb, using: TightDecoder())
        try assertMatches(fb, image, at: rect, h)
    }

    h.test("JPEG tiles land in the right place, right way up") {
        // A two-tone image catches a vertical flip, which a solid colour would
        // not; JPEG is lossy so compare with tolerance.
        let width = 32, height = 32
        var pixels = [UInt32](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                pixels[y * width + x] = y < height / 2 ? rgb(220, 30, 30) : rgb(30, 30, 220)
            }
        }
        guard let jpeg = encodeJPEG(pixels: pixels, width: width, height: height) else {
            throw HarnessError.failed("could not produce a JPEG fixture")
        }
        var bytes: [UInt8] = [0x90]
        bytes += compactLength(jpeg.count)
        bytes += jpeg

        let fb = Framebuffer(width: 64, height: 64)
        let rect = RFBRect(x: 8, y: 8, width: width, height: height)
        try decodeTight(bytes, rect: rect, into: fb, using: TightDecoder())

        let top = fb.row(8 + 4)[8 + 16]
        let bottom = fb.row(8 + height - 4)[8 + 16]
        let topRed = (top >> 16) & 0xFF, topBlue = top & 0xFF
        let bottomRed = (bottom >> 16) & 0xFF, bottomBlue = bottom & 0xFF
        try h.expect(topRed > 150 && topBlue < 100, "top half should stay red, got \(String(format: "%08X", top))")
        try h.expect(bottomBlue > 150 && bottomRed < 100, "bottom half should stay blue, got \(String(format: "%08X", bottom))")
        try h.expect(fb.row(7)[8] == 0xFF00_0000, "must not paint above the rect")
    }

    print("zrle")

    h.test("raw tile") {
        let image = testImage(width: 8, height: 6)
        let flat = image.flatMap { $0 }
        let fb = Framebuffer(width: 32, height: 32)
        let rect = RFBRect(x: 2, y: 2, width: 8, height: 6)
        try decodeZRLE(ZRLEFixture.rect(tiles: [ZRLEFixture.rawTile(flat)], deflater: Deflater()),
                       rect: rect, into: fb, using: ZRLEDecoder())
        try assertMatches(fb, image, at: rect, h)
    }

    h.test("solid tile") {
        let fb = Framebuffer(width: 32, height: 32)
        let rect = RFBRect(x: 0, y: 0, width: 10, height: 10)
        try decodeZRLE(ZRLEFixture.rect(tiles: [ZRLEFixture.solidTile((9, 8, 7))], deflater: Deflater()),
                       rect: rect, into: fb, using: ZRLEDecoder())
        try h.expectEqual(fb.row(9)[9], rgb(9, 8, 7))
    }

    h.test("packed palette tile at 2 bits per pixel") {
        let palette: [(UInt8, UInt8, UInt8)] = [(10, 0, 0), (0, 20, 0), (0, 0, 30)]
        let indices = (0..<5).map { y in (0..<7).map { x in (x + y) % 3 } }
        let fb = Framebuffer(width: 16, height: 16)
        let rect = RFBRect(x: 1, y: 1, width: 7, height: 5)
        let tile = ZRLEFixture.packedPaletteTile(indices: indices, palette: palette)
        try decodeZRLE(ZRLEFixture.rect(tiles: [tile], deflater: Deflater()),
                       rect: rect, into: fb, using: ZRLEDecoder())
        try assertMatches(fb, indices.map { $0.map { palette[$0] } }, at: rect, h)
    }

    h.test("plain RLE tile") {
        let fb = Framebuffer(width: 16, height: 16)
        let rect = RFBRect(x: 0, y: 0, width: 4, height: 3)   // 12 pixels
        let tile = ZRLEFixture.plainRLETile(runs: [((1, 1, 1), 5), ((2, 2, 2), 7)])
        try decodeZRLE(ZRLEFixture.rect(tiles: [tile], deflater: Deflater()),
                       rect: rect, into: fb, using: ZRLEDecoder())
        // The 5-pixel run ends at flat index 4, which on a 4-wide rect is
        // row 1 column 0; the second run starts at index 5.
        try h.expectEqual(fb.row(0)[0], rgb(1, 1, 1), "first run")
        try h.expectEqual(fb.row(1)[0], rgb(1, 1, 1), "last pixel of the first run")
        try h.expectEqual(fb.row(1)[1], rgb(2, 2, 2), "second run starts at index 5")
        try h.expectEqual(fb.row(2)[3], rgb(2, 2, 2), "last pixel")
    }

    h.test("palette RLE tile mixes single pixels and runs") {
        let palette: [(UInt8, UInt8, UInt8)] = [(1, 0, 0), (0, 1, 0)]
        let fb = Framebuffer(width: 16, height: 16)
        let rect = RFBRect(x: 0, y: 0, width: 4, height: 2)   // 8 pixels
        let tile = ZRLEFixture.paletteRLETile(palette: palette,
                                              runs: [(0, 1), (1, 6), (0, 1)])
        try decodeZRLE(ZRLEFixture.rect(tiles: [tile], deflater: Deflater()),
                       rect: rect, into: fb, using: ZRLEDecoder())
        try h.expectEqual(fb.row(0)[0], rgb(1, 0, 0), "single pixel")
        try h.expectEqual(fb.row(0)[1], rgb(0, 1, 0), "run start")
        try h.expectEqual(fb.row(1)[2], rgb(0, 1, 0), "run end")
        try h.expectEqual(fb.row(1)[3], rgb(1, 0, 0), "trailing single pixel")
    }

    h.test("a rect wider than one tile walks tiles in raster order") {
        // 100x70 spans a 2x2 grid of 64px tiles with partial edges; each tile
        // gets a distinct solid colour so misordering is visible.
        let fb = Framebuffer(width: 128, height: 128)
        let rect = RFBRect(x: 0, y: 0, width: 100, height: 70)
        let colours: [(UInt8, UInt8, UInt8)] = [(10, 0, 0), (0, 10, 0), (0, 0, 10), (10, 10, 0)]
        let tiles = colours.map { ZRLEFixture.solidTile($0) }
        try decodeZRLE(ZRLEFixture.rect(tiles: tiles, deflater: Deflater()),
                       rect: rect, into: fb, using: ZRLEDecoder())
        try h.expectEqual(fb.row(0)[0], rgb(10, 0, 0), "top-left tile")
        try h.expectEqual(fb.row(0)[70], rgb(0, 10, 0), "top-right tile")
        try h.expectEqual(fb.row(65)[0], rgb(0, 0, 10), "bottom-left tile")
        try h.expectEqual(fb.row(65)[70], rgb(10, 10, 0), "bottom-right tile")
    }
}

/// Encodes BGRA pixels as JPEG so the Tight JPEG path has real input.
private func encodeJPEG(pixels: [UInt32], width: Int, height: Int) -> [UInt8]? {
    var source = pixels
    let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
    guard let ctx = source.withUnsafeMutableBytes({ raw in
        CGContext(data: raw.baseAddress, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo)
    }), let image = ctx.makeImage() else { return nil }

    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return [UInt8](data as Data)
}
