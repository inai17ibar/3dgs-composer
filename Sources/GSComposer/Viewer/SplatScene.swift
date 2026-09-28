import Foundation
import GSComposerCore
import simd

/// GPU-ready splat data: per-splat 3D covariance is precomputed so the vertex shader only projects it.
struct SplatScene: @unchecked Sendable {
    /// Matches `struct Splat` in the Metal shader: packed_float3 position, float cov[6], uchar4 rgba → 40 bytes.
    static let stride = 40

    let count: Int
    let positions: [Float]
    let gpuData: Data
    let center: SIMD3<Float>
    let radius: Float

    init(cloud: GaussianCloud) {
        count = cloud.count
        positions = cloud.positions
        let bounds = cloud.robustBounds()
        center = bounds.center
        radius = max(bounds.radius, 1e-3)
        var data = Data(count: cloud.count * Self.stride)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            for i in 0..<cloud.count {
                let base = i * Self.stride
                for a in 0..<3 {
                    raw.storeBytes(of: cloud.positions[i * 3 + a], toByteOffset: base + a * 4, as: Float.self)
                }
                let q = simd_quatf(ix: cloud.rotations[i * 4 + 1], iy: cloud.rotations[i * 4 + 2],
                                   iz: cloud.rotations[i * 4 + 3], r: cloud.rotations[i * 4])
                let r = simd_float3x3(q.normalized)
                let s = simd_float3x3(diagonal: SIMD3(cloud.scales[i * 3], cloud.scales[i * 3 + 1], cloud.scales[i * 3 + 2]))
                let m = r * s
                let sigma = m * m.transpose
                let cov: [Float] = [sigma[0][0], sigma[0][1], sigma[0][2], sigma[1][1], sigma[1][2], sigma[2][2]]
                for (k, v) in cov.enumerated() {
                    raw.storeBytes(of: v, toByteOffset: base + 12 + k * 4, as: Float.self)
                }
                for a in 0..<3 {
                    raw.storeBytes(of: Self.byte(cloud.colors[i * 3 + a]), toByteOffset: base + 36 + a, as: UInt8.self)
                }
                raw.storeBytes(of: Self.byte(cloud.opacities[i]), toByteOffset: base + 39, as: UInt8.self)
            }
        }
        gpuData = data
    }

    private static func byte(_ v: Float) -> UInt8 {
        UInt8(min(max((v * 255).rounded(), 0), 255))
    }
}

/// Orbit camera in the OpenCV convention used by COLMAP (x right, y down, z forward).
struct OrbitCamera: Equatable {
    var target = SIMD3<Float>(0, 0, 0)
    var distance: Float = 3
    var yaw: Float = 0
    var pitch: Float = 0.3
    /// COLMAP worlds are usually y-down.
    var up = SIMD3<Float>(0, -1, 0)
    var fovY: Float = 50 * .pi / 180

    private var frame: (a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>) {
        let a = simd_normalize(up)
        let helper: SIMD3<Float> = abs(a.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 0, 1)
        let b = simd_normalize(simd_cross(a, helper))
        let c = simd_cross(a, b)
        return (a, b, c)
    }

    var eye: SIMD3<Float> {
        let f = frame
        let dir = cos(pitch) * (cos(yaw) * f.b + sin(yaw) * f.c) + sin(pitch) * f.a
        return target + distance * dir
    }

    /// Rows of the world→camera rotation.
    var basis: (right: SIMD3<Float>, down: SIMD3<Float>, forward: SIMD3<Float>) {
        let forward = simd_normalize(target - eye)
        let down = -simd_normalize(up)
        var right = simd_cross(down, forward)
        if simd_length(right) < 1e-5 { right = frame.b }
        right = simd_normalize(right)
        return (right, simd_cross(forward, right), forward)
    }

    mutating func orbit(dx: Float, dy: Float) {
        yaw -= dx * 0.008
        pitch = min(max(pitch + dy * 0.008, -1.5), 1.5)
    }

    mutating func pan(dx: Float, dy: Float, viewHeight: Float) {
        let b = basis
        let scale = 2 * distance * tan(fovY / 2) / max(viewHeight, 1)
        target += (-dx * b.right - dy * b.down) * scale
    }

    mutating func zoom(_ factor: Float) {
        distance = min(max(distance * factor, 1e-3), 1e5)
    }

    mutating func frame(center: SIMD3<Float>, radius: Float) {
        target = center
        distance = radius * 1.6
    }
}
