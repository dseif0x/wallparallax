import CoreGraphics
import Metal
import QuartzCore

/// Renders a `DepthPhoto` as a dense mesh whose vertices are displaced by the depth map:
/// far pixels follow your head, near pixels stay at the screen plane — per-pixel parallax.
final class DepthRenderer {
    let layer = CAMetalLayer()

    private struct Uniforms {
        var viewSize: SIMD2<Float>
        var shift: SIMD2<Float>
        var quadOrigin: SIMD2<Float>
        var quadSize: SIMD2<Float>
        var zoom: Float
        var padding: Float = 0
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let colorTexture: MTLTexture
    private let depthMapTexture: MTLTexture
    private let vertexBuffer: MTLBuffer
    private let indexBuffer: MTLBuffer
    private let indexCount: Int
    private var zBuffer: MTLTexture?
    private var uniforms: Uniforms

    init?(photo: DepthPhoto, screen: CGSize, overscan: CGFloat, scale: CGFloat) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let shared = Self.sharedResources(for: device)
        else { return nil }
        self.device = device
        self.queue = queue
        pipeline = shared.pipeline
        depthState = shared.depthState

        guard let color = Self.makeTexture(photo.color, device: device, queue: queue, gray: false),
              let depth = Self.makeTexture(photo.depth, device: device, queue: queue, gray: true)
        else { return nil }
        colorTexture = color
        depthMapTexture = depth

        // Grid mesh in UV space, matching the photo's aspect ratio.
        let cols = 240
        let rows = max(2, Int(Double(cols) * Double(photo.color.height) / Double(photo.color.width)))
        var uvs: [SIMD2<Float>] = []
        uvs.reserveCapacity((cols + 1) * (rows + 1))
        for r in 0...rows {
            for c in 0...cols { uvs.append(SIMD2(Float(c) / Float(cols), Float(r) / Float(rows))) }
        }
        var indices: [UInt32] = []
        indices.reserveCapacity(cols * rows * 6)
        for r in 0..<rows {
            for c in 0..<cols {
                let i = UInt32(r * (cols + 1) + c), below = i + UInt32(cols + 1)
                indices += [i, i + 1, below, i + 1, below + 1, below]
            }
        }
        guard let vb = device.makeBuffer(bytes: uvs, length: uvs.count * MemoryLayout<SIMD2<Float>>.stride),
              let ib = device.makeBuffer(bytes: indices, length: indices.count * MemoryLayout<UInt32>.stride)
        else { return nil }
        vertexBuffer = vb
        indexBuffer = ib
        indexCount = indices.count

        // Aspect-fill the photo over the overscanned screen rect (points, y up).
        let target = CGRect(x: -overscan, y: -overscan, width: screen.width + 2 * overscan, height: screen.height + 2 * overscan)
        let fill = max(target.width / CGFloat(photo.color.width), target.height / CGFloat(photo.color.height))
        let quad = CGSize(width: CGFloat(photo.color.width) * fill, height: CGFloat(photo.color.height) * fill)
        uniforms = Uniforms(
            viewSize: SIMD2(Float(screen.width), Float(screen.height)),
            shift: .zero,
            quadOrigin: SIMD2(Float(target.midX - quad.width / 2), Float(target.midY - quad.height / 2)),
            quadSize: SIMD2(Float(quad.width), Float(quad.height)),
            zoom: 0)

        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.contentsScale = scale
        layer.frame = CGRect(origin: .zero, size: screen)
        layer.drawableSize = CGSize(width: screen.width * scale, height: screen.height * scale)
    }

    /// `shift` is the displacement (points) of something infinitely far away; `zoom` the extra scale of the nearest point.
    func draw(shift: CGPoint, zoom: CGFloat) {
        uniforms.shift = SIMD2(Float(shift.x), Float(shift.y))
        uniforms.zoom = Float(zoom)
        guard let drawable = layer.nextDrawable(),
              let commands = queue.makeCommandBuffer()
        else { return }
        encode(into: drawable.texture, commands: commands)
        commands.present(drawable)
        commands.commit()
    }

    /// Renders offscreen (used by `--snapshot`).
    func image(shift: CGPoint, zoom: CGFloat) -> CGImage? {
        uniforms.shift = SIMD2(Float(shift.x), Float(shift.y))
        uniforms.zoom = Float(zoom)
        let w = Int(layer.drawableSize.width), h = Int(layer.drawableSize.height)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let target = device.makeTexture(descriptor: desc), let commands = queue.makeCommandBuffer() else { return nil }
        encode(into: target, commands: commands)
        commands.commit()
        commands.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        target.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        return bytes.withUnsafeMutableBytes {
            CGContext(data: $0.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)?.makeImage()
        }
    }

    private func encode(into target: MTLTexture, commands: MTLCommandBuffer) {
        if zBuffer?.width != target.width || zBuffer?.height != target.height {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: target.width,
                                                                height: target.height, mipmapped: false)
            desc.usage = .renderTarget
            desc.storageMode = .private
            zBuffer = device.makeTexture(descriptor: desc)
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = zBuffer
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare

        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setVertexTexture(depthMapTexture, index: 0)
        encoder.setFragmentTexture(colorTexture, index: 0)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint32,
                                      indexBuffer: indexBuffer, indexBufferOffset: 0)
        encoder.endEncoding()
    }

    // MARK: Textures

    /// Uploads an image after redrawing it into a known layout (RGBA8 sRGB, or 8-bit gray).
    /// Decoded images come in many layouts (RGBA, XRGB, BGRA, 16-bit, P3...); letting a texture
    /// loader guess can shift channels, e.g. reading XRGB JPEGs as RGBA tints everything pink.
    private static func makeTexture(_ image: CGImage, device: MTLDevice, queue: MTLCommandQueue, gray: Bool) -> MTLTexture? {
        let width = image.width, height = image.height
        let bytesPerPixel = gray ? 1 : 4
        let rowBytes = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: rowBytes * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!
            let info = gray ? CGImageAlphaInfo.none.rawValue
                : CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: rowBytes, space: space, bitmapInfo: info) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: gray ? .r8Unorm : .rgba8Unorm,
                                                            width: width, height: height, mipmapped: !gray)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        // Row 0 of the bitmap is the top of the image, matching texture v = 0 at the top.
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: pixels, bytesPerRow: rowBytes)
        if !gray, let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            commands.commit()
        }
        return texture
    }

    // MARK: Shared pipeline

    private struct Shared {
        let pipeline: MTLRenderPipelineState
        let depthState: MTLDepthStencilState
    }

    private static var shared: [ObjectIdentifier: Shared] = [:]

    private static func sharedResources(for device: MTLDevice) -> Shared? {
        let id = ObjectIdentifier(device)
        if let existing = shared[id] { return existing }
        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "depthVertex")
            desc.fragmentFunction = library.makeFunction(name: "depthFragment")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            desc.depthAttachmentPixelFormat = .depth32Float
            let pipeline = try device.makeRenderPipelineState(descriptor: desc)

            let depthDesc = MTLDepthStencilDescriptor()
            depthDesc.depthCompareFunction = .less
            depthDesc.isDepthWriteEnabled = true
            guard let depthState = device.makeDepthStencilState(descriptor: depthDesc) else { return nil }

            let resources = Shared(pipeline: pipeline, depthState: depthState)
            shared[id] = resources
            return resources
        } catch {
            NSLog("WallParallax: failed to build depth pipeline: \(error)")
            return nil
        }
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 viewSize;
        float2 shift;
        float2 quadOrigin;
        float2 quadSize;
        float zoom;
        float padding;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VertexOut depthVertex(uint vid [[vertex_id]],
                                 const device float2 *uvs [[buffer(0)]],
                                 constant Uniforms &u [[buffer(1)]],
                                 texture2d<float> depthMap [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 uv = uvs[vid];
        float near = depthMap.sample(s, uv, level(0)).r;   // 1 = near, 0 = far
        float far = 1.0 - near;

        // Texture v runs top→bottom, screen points run bottom→top.
        float2 p = u.quadOrigin + float2(uv.x, 1.0 - uv.y) * u.quadSize;
        p += u.shift * far;
        float2 center = u.viewSize * 0.5;
        p = (p - center) * (1.0 + u.zoom * near) + center;

        VertexOut out;
        out.position = float4(p / u.viewSize * 2.0 - 1.0, 0.02 + far * 0.96, 1.0);
        out.uv = uv;
        return out;
    }

    fragment float4 depthFragment(VertexOut in [[stage_in]], texture2d<float> color [[texture(0)]]) {
        constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
        return color.sample(s, in.uv);
    }
    """
}
