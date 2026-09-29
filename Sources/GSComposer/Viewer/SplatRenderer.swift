import Foundation
import GSComposerCore
import Metal
import MetalKit
import simd

struct SplatUniforms {
    var right: SIMD4<Float>
    var down: SIMD4<Float>
    var forward: SIMD4<Float>
    var eye: SIMD4<Float>
    var focal: SIMD2<Float>
    var viewport: SIMD2<Float>
}

/// Renders 3D Gaussians as screen-space ellipses (EWA splatting), alpha-blended back to front.
/// Sorting runs on a background queue and is re-issued whenever the view direction changes.
final class SplatRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var splatBuffer: MTLBuffer?
    private var orderBuffer: MTLBuffer?
    private var scene: SplatScene?
    private var sortedFor: OrbitCamera?
    private var sortInFlight = false
    private var generation = 0
    private let sortQueue = DispatchQueue(label: "splat.sort", qos: .userInteractive)

    var camera = OrbitCamera()
    var background = MTLClearColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1)
    weak var view: MTKView?

    init?(view: MTKView) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .invalid
        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "splatVertex")
            desc.fragmentFunction = library.makeFunction(name: "splatFragment")
            let color = desc.colorAttachments[0]!
            color.pixelFormat = view.colorPixelFormat
            color.isBlendingEnabled = true
            color.rgbBlendOperation = .add
            color.alphaBlendOperation = .add
            color.sourceRGBBlendFactor = .one
            color.sourceAlphaBlendFactor = .one
            color.destinationRGBBlendFactor = .oneMinusSourceAlpha
            color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            NSLog("Splat pipeline error: \(error)")
            return nil
        }
        self.view = view
        super.init()
    }

    var hasScene: Bool { scene != nil }
    var sceneForCamera: SplatScene? { scene }

    func setScene(_ newScene: SplatScene, resetCamera: Bool) {
        generation += 1
        scene = newScene
        splatBuffer = newScene.gpuData.withUnsafeBytes { raw in
            raw.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: max(raw.count, 16), options: .storageModeShared) }
        }
        orderBuffer = nil
        sortedFor = nil
        if resetCamera { camera.frame(center: newScene.center, radius: newScene.radius) }
        requestSort()
        view?.needsDisplay = true
    }

    func cameraChanged() {
        view?.needsDisplay = true
    }

    private func requestSort() {
        guard let scene, !sortInFlight else { return }
        let cam = camera
        let b = cam.basis
        let gen = generation
        sortInFlight = true
        sortQueue.async { [weak self] in
            let order = DepthSorter.backToFront(positions: scene.positions, cameraPosition: cam.eye, forward: b.forward)
            DispatchQueue.main.async {
                guard let self else { return }
                self.sortInFlight = false
                guard gen == self.generation else { self.requestSort(); return }
                self.orderBuffer = order.withUnsafeBytes { raw in
                    raw.baseAddress.flatMap { self.device.makeBuffer(bytes: $0, length: max(raw.count, 16), options: .storageModeShared) }
                }
                self.sortedFor = cam
                self.view?.needsDisplay = true
            }
        }
    }

    private func needsResort() -> Bool {
        guard let sorted = sortedFor else { return true }
        let a = sorted.basis.forward, b = camera.basis.forward
        let moved = simd_length(sorted.eye - camera.eye) / max(camera.distance, 1e-3)
        return simd_dot(a, b) < 0.999 || moved > 0.02
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        view.needsDisplay = true
    }

    func draw(in view: MTKView) {
        if scene != nil, needsResort() { requestSort() }
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer() else { return }
        pass.colorAttachments[0].clearColor = background
        pass.colorAttachments[0].loadAction = .clear
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        if let scene, let splatBuffer, let orderBuffer, scene.count > 0 {
            let size = view.drawableSize
            let focal = Float(size.height) / 2 / tan(camera.fovY / 2)
            let b = camera.basis
            var u = SplatUniforms(right: SIMD4(b.right, 0), down: SIMD4(b.down, 0), forward: SIMD4(b.forward, 0),
                                  eye: SIMD4(camera.eye, 0), focal: SIMD2(focal, focal),
                                  viewport: SIMD2(Float(size.width), Float(size.height)))
            enc.setRenderPipelineState(pipeline)
            enc.setVertexBuffer(splatBuffer, offset: 0, index: 0)
            enc.setVertexBuffer(orderBuffer, offset: 0, index: 1)
            enc.setVertexBytes(&u, length: MemoryLayout<SplatUniforms>.stride, index: 2)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: scene.count)
        }
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Splat {
        packed_float3 position;
        float cov[6];
        uchar4 rgba;
    };

    struct Uniforms {
        float4 right;
        float4 down;
        float4 forward;
        float4 eye;
        float2 focal;
        float2 viewport;
    };

    struct VOut {
        float4 position [[position]];
        float4 color;
        float2 uv;
    };

    vertex VOut splatVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                            const device Splat *splats [[buffer(0)]],
                            const device uint *order [[buffer(1)]],
                            constant Uniforms &u [[buffer(2)]]) {
        VOut out;
        out.position = float4(0, 0, 2, 1);
        out.color = float4(0);
        out.uv = float2(0);

        Splat s = splats[order[iid]];
        float3 d = float3(s.position) - u.eye.xyz;
        float3 p = float3(dot(u.right.xyz, d), dot(u.down.xyz, d), dot(u.forward.xyz, d));
        if (p.z < 0.02) return out;

        float2 center = float2(u.focal.x * p.x / p.z, u.focal.y * p.y / p.z);
        float2 half_vp = u.viewport * 0.5;
        if (any(abs(center) > half_vp * 1.3)) return out;

        float3x3 vrk = float3x3(float3(s.cov[0], s.cov[1], s.cov[2]),
                                float3(s.cov[1], s.cov[3], s.cov[4]),
                                float3(s.cov[2], s.cov[4], s.cov[5]));
        // W: world → camera rotation (rows right/down/forward).
        float3x3 W = transpose(float3x3(u.right.xyz, u.down.xyz, u.forward.xyz));
        float z2 = p.z * p.z;
        float3x3 J = float3x3(float3(u.focal.x / p.z, 0, 0),
                              float3(0, u.focal.y / p.z, 0),
                              float3(-u.focal.x * p.x / z2, -u.focal.y * p.y / z2, 0));
        float3x3 T = J * W;
        float3x3 cov = T * vrk * transpose(T);
        float a = cov[0][0] + 0.3;
        float b = cov[0][1];
        float c = cov[1][1] + 0.3;

        float mid = 0.5 * (a + c);
        float radius = length(float2(0.5 * (a - c), b));
        float l1 = mid + radius;
        float l2 = max(mid - radius, 0.1);
        if (l1 <= 0) return out;
        float2 v1 = abs(b) > 1e-8 ? normalize(float2(b, l1 - a)) : (a >= c ? float2(1, 0) : float2(0, 1));
        float2 major = min(sqrt(2.0 * l1), 1024.0) * v1;
        float2 minor = min(sqrt(2.0 * l2), 1024.0) * float2(v1.y, -v1.x);

        float2 corner = float2((vid & 1) ? 2.0 : -2.0, (vid & 2) ? 2.0 : -2.0);
        float2 pixel = center + corner.x * major + corner.y * minor;
        // Image space is y-down; NDC is y-up.
        out.position = float4(pixel.x / half_vp.x, -pixel.y / half_vp.y, 0.5, 1);
        out.color = float4(s.rgba) / 255.0;
        out.uv = corner;
        return out;
    }

    fragment float4 splatFragment(VOut in [[stage_in]]) {
        float a = -dot(in.uv, in.uv);
        if (a < -4.0) discard_fragment();
        float alpha = exp(a) * in.color.a;
        if (alpha < 1.0 / 255.0) discard_fragment();
        return float4(in.color.rgb * alpha, alpha);
    }
    """
}
