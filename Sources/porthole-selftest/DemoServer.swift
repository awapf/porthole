import Foundation
import CoreGraphics
import CoreText
import PortholeCore

/// A local RFB server that paints a moving test pattern, so the client's
/// rendering, input and resize handling can be exercised without a VM:
///
///     porthole-selftest --serve 5999
///     porthole --direct 127.0.0.1:5999 --window
func runDemoServer(port requestedPort: UInt16) -> Never {
    let server: LoopbackServer
    do {
        server = try LoopbackServer(width: 1280, height: 800, preferredPort: requestedPort)
    } catch {
        FileHandle.standardError.write(Data("demo server failed: \(error)\n".utf8))
        exit(1)
    }
    server.desktopName = "porthole demo"

    print("demo RFB server listening on 127.0.0.1:\(server.port)")
    print("connect with:  porthole --direct 127.0.0.1:\(server.port) --window")
    print("ctrl-c to stop")

    let painting = NSLock()
    var size = (1280, 800)
    var frame = 0

    server.onResize = { w, h in
        painting.lock()
        size = (w, h)
        painting.unlock()
        print("client asked for \(w)x\(h)")
    }

    server.start(repeatedly: true) {
        print("client connected")
        fflush(stdout)
        Thread.detachNewThread {
            while true {
                painting.lock()
                let (width, height) = size
                painting.unlock()
                let pixels = renderDemoFrame(width: width, height: height, frame: frame)
                do {
                    try server.sendRawImage(
                        rect: RFBRect(x: 0, y: 0, width: width, height: height),
                        pixels: pixels)
                } catch {
                    return
                }
                frame += 1
                Thread.sleep(forTimeInterval: 1.0 / 20.0)
            }
        }
    }

    while true { Thread.sleep(forTimeInterval: 1) }
}

/// Draws a frame whose every element proves something: the gradient shows
/// colour fidelity, the grid shows geometry, the moving box shows liveness,
/// and the caption shows the negotiated resolution.
private func renderDemoFrame(width: Int, height: Int, frame: Int) -> [UInt32] {
    var pixels = [UInt32](repeating: 0xFF00_0000, count: width * height)
    let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
    pixels.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: bitmapInfo) else { return }

        let colours = [CGColor(red: 0.05, green: 0.07, blue: 0.15, alpha: 1),
                       CGColor(red: 0.18, green: 0.10, blue: 0.30, alpha: 1)]
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: colours as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: .zero,
                                   end: CGPoint(x: width, y: height), options: [])
        }

        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.10))
        ctx.setLineWidth(1)
        for x in stride(from: 0, to: width, by: 64) {
            ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: height))
        }
        for y in stride(from: 0, to: height, by: 64) {
            ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: width, y: y))
        }
        ctx.strokePath()

        // Corner markers make cropping or an off-by-one viewport obvious.
        ctx.setFillColor(CGColor(red: 1, green: 0.3, blue: 0.3, alpha: 1))
        for (cx, cy) in [(0, 0), (width - 40, 0), (0, height - 40), (width - 40, height - 40)] {
            ctx.fill(CGRect(x: cx, y: cy, width: 40, height: 40))
        }

        let angle = Double(frame) * 0.05
        let boxX = Double(width) / 2 + cos(angle) * Double(width) / 3.5 - 40
        let boxY = Double(height) / 2 + sin(angle) * Double(height) / 3.5 - 40
        ctx.setFillColor(CGColor(red: 0.4, green: 0.9, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: boxX, y: boxY, width: 80, height: 80))

        let caption = "porthole demo — \(width)x\(height) — frame \(frame)"
        // CoreText attribute keys, so this file needs no AppKit.
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: CTFontCreateWithName("Menlo" as CFString, 22, nil),
            kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 1, alpha: 0.9),
        ]
        let attributed = CFAttributedStringCreate(nil, caption as CFString,
                                                  attributes as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attributed)
        ctx.textPosition = CGPoint(x: 60, y: Double(height) - 80)
        CTLineDraw(line, ctx)
    }
    return pixels
}
