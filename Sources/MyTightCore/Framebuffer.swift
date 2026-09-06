import Foundation

/// Remote screen contents as little-endian BGRA words, directly uploadable to
/// an `MTLPixelFormat.bgra8Unorm` texture.
public final class Framebuffer {
    public private(set) var width: Int
    public private(set) var height: Int
    public private(set) var pixels: UnsafeMutablePointer<UInt32>
    public let lock = NSLock()

    public var rowStride: Int { width }
    public var byteCount: Int { width * height * 4 }

    public init(width: Int, height: Int) {
        self.width = max(width, 1)
        self.height = max(height, 1)
        let count = self.width * self.height
        pixels = .allocate(capacity: count)
        pixels.initialize(repeating: 0xFF00_0000, count: count)
    }

    /// Resizes, preserving the overlapping top-left region so a resize does not
    /// flash black before the server repaints.
    public func resize(width newWidth: Int, height newHeight: Int) {
        let w = max(newWidth, 1), h = max(newHeight, 1)
        guard w != width || h != height else { return }
        let fresh = UnsafeMutablePointer<UInt32>.allocate(capacity: w * h)
        fresh.initialize(repeating: 0xFF00_0000, count: w * h)
        let copyW = min(w, width), copyH = min(h, height)
        for row in 0..<copyH {
            (fresh + row * w).update(from: pixels + row * width, count: copyW)
        }
        pixels.deallocate()
        pixels = fresh
        width = w
        height = h
    }

    @inline(__always)
    public func row(_ y: Int) -> UnsafeMutablePointer<UInt32> { pixels + y * width }

    public func fill(_ rect: RFBRect, with colour: UInt32) {
        let x0 = max(0, rect.x), y0 = max(0, rect.y)
        let x1 = min(width, rect.x + rect.width), y1 = min(height, rect.y + rect.height)
        guard x1 > x0, y1 > y0 else { return }
        for y in y0..<y1 {
            let dst = row(y) + x0
            dst.update(repeating: colour, count: x1 - x0)
        }
    }

    /// CopyRect. Overlap-safe in both directions.
    public func copy(from src: RFBRect, toX dx: Int, toY dy: Int) {
        let w = src.width, h = src.height
        guard w > 0, h > 0 else { return }
        guard src.x >= 0, src.y >= 0, src.x + w <= width, src.y + h <= height,
              dx >= 0, dy >= 0, dx + w <= width, dy + h <= height else { return }
        if dy > src.y {
            for i in stride(from: h - 1, through: 0, by: -1) {
                memmove(row(dy + i) + dx, row(src.y + i) + src.x, w * 4)
            }
        } else {
            for i in 0..<h {
                memmove(row(dy + i) + dx, row(src.y + i) + src.x, w * 4)
            }
        }
    }

    deinit { pixels.deallocate() }
}
