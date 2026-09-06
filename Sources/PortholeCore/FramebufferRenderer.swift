import Foundation
import Metal

/// Uploads dirty framebuffer rectangles into a texture and draws it to a target.
///
/// Kept free of AppKit so it can be driven either by a `CAMetalLayer` in the
/// app or by an offscreen texture in the self-test, which is the only way to
/// check the shader and viewport arithmetic without a screen recorder.
public final class FramebufferRenderer {
    public let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private(set) public var texture: MTLTexture?

    /// Letterbox to preserve aspect ratio instead of stretching.
    public var scaleToFit = true

    public enum RendererError: Error, CustomStringConvertible {
        case noDevice
        case shader(String)
        public var description: String {
            switch self {
            case .noDevice: return "no Metal device is available"
            case .shader(let s): return "Metal shader setup failed: \(s)"
            }
        }
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct VertexOut { float4 position [[position]]; float2 uv; };
    vertex VertexOut vertexMain(uint id [[vertex_id]]) {
        // One oversized triangle covers the viewport with no vertex buffer.
        const float2 corners[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        VertexOut out;
        out.position = float4(corners[id], 0, 1);
        // Flip vertically: clip space counts up, the framebuffer counts down.
        out.uv = corners[id] * float2(0.5, -0.5) + 0.5;
        return out;
    }
    fragment float4 fragmentMain(VertexOut in [[stage_in]],
                                 texture2d<float> frame [[texture(0)]],
                                 sampler smp [[sampler(0)]]) {
        // RFB carries no alpha; force it opaque.
        return float4(frame.sample(smp, in.uv).rgb, 1.0);
    }
    """

    public init(device: MTLDevice? = nil, pixelFormat: MTLPixelFormat = .bgra8Unorm) throws {
        guard let device = device ?? MTLCreateSystemDefaultDevice() else {
            throw RendererError.noDevice
        }
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw RendererError.noDevice }
        self.queue = queue

        do {
            // Compiled at runtime so the package builds without Xcode's metal
            // toolchain, which Command Line Tools alone does not provide.
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "vertexMain")
            descriptor.fragmentFunction = library.makeFunction(name: "fragmentMain")
            descriptor.colorAttachments[0].pixelFormat = pixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw RendererError.shader("\(error)")
        }

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw RendererError.noDevice
        }
        self.sampler = sampler
    }

    /// Drops the texture so the next upload recreates it at the new size.
    public func invalidateTexture() { texture = nil }

    /// Copies `rects` out of `framebuffer` into the texture, taking the
    /// framebuffer's lock. Returns true when the texture was recreated, in
    /// which case the caller's dirty list was ignored and everything uploaded.
    @discardableResult
    public func upload(from framebuffer: Framebuffer, rects: [RFBRect]) -> Bool {
        framebuffer.lock.lock()
        defer { framebuffer.lock.unlock() }

        var recreated = false
        if texture == nil || texture!.width != framebuffer.width || texture!.height != framebuffer.height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: framebuffer.width, height: framebuffer.height, mipmapped: false)
            descriptor.usage = .shaderRead
            descriptor.storageMode = .shared
            texture = device.makeTexture(descriptor: descriptor)
            recreated = true
        }
        guard let texture else { return false }

        // A fresh texture holds nothing, so a partial upload would leave holes.
        let regions = recreated
            ? [RFBRect(x: 0, y: 0, width: framebuffer.width, height: framebuffer.height)]
            : rects

        for rect in regions {
            let x = max(0, rect.x), y = max(0, rect.y)
            let w = min(rect.width, framebuffer.width - x)
            let h = min(rect.height, framebuffer.height - y)
            guard w > 0, h > 0 else { continue }
            texture.replace(region: MTLRegionMake2D(x, y, w, h),
                            mipmapLevel: 0,
                            withBytes: framebuffer.row(y) + x,
                            bytesPerRow: framebuffer.rowStride * 4)
        }
        return recreated
    }

    /// The rect of the target that the remote image occupies, in target pixels.
    public func viewport(targetWidth: Double, targetHeight: Double) -> MTLViewport {
        guard let texture else {
            return MTLViewport(originX: 0, originY: 0, width: targetWidth, height: targetHeight,
                               znear: 0, zfar: 1)
        }
        guard scaleToFit else {
            return MTLViewport(originX: 0, originY: 0,
                               width: Double(texture.width), height: Double(texture.height),
                               znear: 0, zfar: 1)
        }
        let scale = min(targetWidth / Double(texture.width), targetHeight / Double(texture.height))
        let width = Double(texture.width) * scale
        let height = Double(texture.height) * scale
        return MTLViewport(originX: (targetWidth - width) / 2,
                           originY: (targetHeight - height) / 2,
                           width: width, height: height, znear: 0, zfar: 1)
    }

    /// Draws into `target`. `waitForCompletion` is for offscreen readback;
    /// the on-screen path presents a drawable instead and never waits.
    public func render(to target: MTLTexture,
                       present: MTLDrawable? = nil,
                       waitForCompletion: Bool = false) {
        guard let texture, let buffer = queue.makeCommandBuffer() else { return }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        descriptor.colorAttachments[0].storeAction = .store

        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setViewport(viewport(targetWidth: Double(target.width),
                                     targetHeight: Double(target.height)))
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        if let present { buffer.present(present) }
        buffer.commit()
        if waitForCompletion { buffer.waitUntilCompleted() }
    }

    /// Renders to a private offscreen texture and reads it back as BGRA words.
    public func renderOffscreen(width: Int, height: Int) -> [UInt32]? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor) else { return nil }
        render(to: target, waitForCompletion: true)

        var out = [UInt32](repeating: 0, count: width * height)
        out.withUnsafeMutableBytes { raw in
            target.getBytes(raw.baseAddress!, bytesPerRow: width * 4,
                            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return out
    }
}
