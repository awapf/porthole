import Foundation
import Metal
import MyTightCore

/// Renders offscreen and reads the pixels back, so the shader, the vertical
/// flip and the letterbox arithmetic are checked without a display or a screen
/// recording permission.
func runRenderTests(_ h: Harness) {
    print("render")

    guard let device = MTLCreateSystemDefaultDevice() else {
        print("  skip (no Metal device)")
        return
    }

    h.test("a framebuffer renders 1:1 with the right orientation") {
        let fb = Framebuffer(width: 4, height: 4)
        // Distinct corners catch a flip or a transpose.
        fb.fill(RFBRect(x: 0, y: 0, width: 4, height: 4), with: rgb(0, 0, 0))
        fb.row(0)[0] = rgb(255, 0, 0)      // top-left
        fb.row(0)[3] = rgb(0, 255, 0)      // top-right
        fb.row(3)[0] = rgb(0, 0, 255)      // bottom-left
        fb.row(3)[3] = rgb(255, 255, 0)    // bottom-right

        let renderer = try FramebufferRenderer(device: device)
        renderer.scaleToFit = true
        renderer.upload(from: fb, rects: [])
        guard let pixels = renderer.renderOffscreen(width: 4, height: 4) else {
            throw HarnessError.failed("offscreen render produced nothing")
        }

        func at(_ x: Int, _ y: Int) -> UInt32 { pixels[y * 4 + x] }
        try h.expectEqual(at(0, 0), rgb(255, 0, 0), "top-left")
        try h.expectEqual(at(3, 0), rgb(0, 255, 0), "top-right")
        try h.expectEqual(at(0, 3), rgb(0, 0, 255), "bottom-left")
        try h.expectEqual(at(3, 3), rgb(255, 255, 0), "bottom-right")
    }

    h.test("alpha is forced opaque regardless of what the wire carried") {
        let fb = Framebuffer(width: 2, height: 2)
        // JPEG tiles leave the top byte as CoreGraphics wrote it, which may be
        // zero; the shader must not let that show through as transparency.
        for y in 0..<2 { for x in 0..<2 { fb.row(y)[x] = 0x0010_2030 } }
        let renderer = try FramebufferRenderer(device: device)
        renderer.upload(from: fb, rects: [])
        guard let pixels = renderer.renderOffscreen(width: 2, height: 2) else {
            throw HarnessError.failed("offscreen render produced nothing")
        }
        try h.expectEqual((pixels[0] >> 24) & 0xFF, 0xFF, "alpha")
        try h.expectEqual(pixels[0] & 0x00FF_FFFF, 0x0010_2030, "colour preserved")
    }

    h.test("a wide desktop letterboxes instead of stretching") {
        // 8x2 content in a 8x8 target: 2 rows of content centred, black bars.
        let fb = Framebuffer(width: 8, height: 2)
        fb.fill(RFBRect(x: 0, y: 0, width: 8, height: 2), with: rgb(200, 100, 50))
        let renderer = try FramebufferRenderer(device: device)
        renderer.scaleToFit = true
        renderer.upload(from: fb, rects: [])

        let viewport = renderer.viewport(targetWidth: 8, targetHeight: 8)
        try h.expectEqual(viewport.width, 8, "content spans the full width")
        try h.expectEqual(viewport.height, 2, "content keeps its aspect ratio")
        try h.expectEqual(viewport.originY, 3, "content is vertically centred")

        guard let pixels = renderer.renderOffscreen(width: 8, height: 8) else {
            throw HarnessError.failed("offscreen render produced nothing")
        }
        try h.expectEqual(pixels[0], rgb(0, 0, 0), "top bar is black")
        try h.expectEqual(pixels[4 * 8 + 4], rgb(200, 100, 50), "centre is content")
        try h.expectEqual(pixels[7 * 8 + 4], rgb(0, 0, 0), "bottom bar is black")
    }

    h.test("a dirty rect updates only its own pixels") {
        let fb = Framebuffer(width: 8, height: 8)
        fb.fill(RFBRect(x: 0, y: 0, width: 8, height: 8), with: rgb(10, 10, 10))
        let renderer = try FramebufferRenderer(device: device)
        renderer.scaleToFit = false
        renderer.upload(from: fb, rects: [])

        // Change two pixels but declare only one of them dirty; the undeclared
        // one must not appear, proving uploads honour the rect list.
        fb.row(1)[1] = rgb(255, 0, 0)
        fb.row(6)[6] = rgb(0, 255, 0)
        renderer.upload(from: fb, rects: [RFBRect(x: 1, y: 1, width: 1, height: 1)])

        guard let pixels = renderer.renderOffscreen(width: 8, height: 8) else {
            throw HarnessError.failed("offscreen render produced nothing")
        }
        try h.expectEqual(pixels[1 * 8 + 1], rgb(255, 0, 0), "declared dirty pixel")
        try h.expectEqual(pixels[6 * 8 + 6], rgb(10, 10, 10), "undeclared pixel")
    }

    h.test("a resize forces a full re-upload rather than a partial one") {
        let fb = Framebuffer(width: 4, height: 4)
        fb.fill(RFBRect(x: 0, y: 0, width: 4, height: 4), with: rgb(1, 2, 3))
        let renderer = try FramebufferRenderer(device: device)
        renderer.scaleToFit = false
        renderer.upload(from: fb, rects: [])

        fb.resize(width: 8, height: 8)
        fb.fill(RFBRect(x: 0, y: 0, width: 8, height: 8), with: rgb(9, 8, 7))
        // An empty dirty list would upload nothing if the size change were
        // missed, leaving the old 4x4 texture on screen.
        let recreated = renderer.upload(from: fb, rects: [])
        try h.expect(recreated, "texture should have been recreated")
        try h.expectEqual(renderer.texture?.width ?? 0, 8, "texture width")

        guard let pixels = renderer.renderOffscreen(width: 8, height: 8) else {
            throw HarnessError.failed("offscreen render produced nothing")
        }
        try h.expectEqual(pixels[7 * 8 + 7], rgb(9, 8, 7), "far corner after resize")
    }
}
