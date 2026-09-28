import Foundation

/// A set of 3D Gaussians stored as flat, GPU-friendly arrays.
///
/// - `positions`: xyz per splat
/// - `scales`: linear (not log) standard deviations per axis
/// - `rotations`: unit quaternion (w, x, y, z) per splat
/// - `opacities`: 0...1 (sigmoid already applied)
/// - `colors`: linear RGB 0...1 derived from the SH DC term
public struct GaussianCloud: Sendable, Equatable {
    public var positions: [Float]
    public var scales: [Float]
    public var rotations: [Float]
    public var opacities: [Float]
    public var colors: [Float]

    public var count: Int { opacities.count }

    public init(positions: [Float], scales: [Float], rotations: [Float], opacities: [Float], colors: [Float]) {
        precondition(positions.count == opacities.count * 3)
        precondition(scales.count == opacities.count * 3)
        precondition(rotations.count == opacities.count * 4)
        precondition(colors.count == opacities.count * 3)
        self.positions = positions
        self.scales = scales
        self.rotations = rotations
        self.opacities = opacities
        self.colors = colors
    }

    public static let empty = GaussianCloud(positions: [], scales: [], rotations: [], opacities: [], colors: [])

    public func position(_ i: Int) -> SIMD3<Float> {
        SIMD3(positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2])
    }

    /// Robust scene bounds: per-axis median as the center and the 90th percentile distance as the radius.
    /// Outlier splats (sky, floaters) are common in 3DGS output, so min/max would be misleading.
    public func robustBounds(maxSamples: Int = 50_000) -> (center: SIMD3<Float>, radius: Float) {
        guard count > 0 else { return (.zero, 1) }
        let step = max(1, count / maxSamples)
        var xs: [Float] = [], ys: [Float] = [], zs: [Float] = []
        xs.reserveCapacity(count / step + 1)
        ys.reserveCapacity(count / step + 1)
        zs.reserveCapacity(count / step + 1)
        var i = 0
        while i < count {
            xs.append(positions[i * 3]); ys.append(positions[i * 3 + 1]); zs.append(positions[i * 3 + 2])
            i += step
        }
        func median(_ v: [Float]) -> Float {
            let s = v.sorted()
            return s[s.count / 2]
        }
        let center = SIMD3(median(xs), median(ys), median(zs))
        var dists = [Float]()
        dists.reserveCapacity(xs.count)
        for k in 0..<xs.count {
            let d = SIMD3(xs[k], ys[k], zs[k]) - center
            dists.append((d * d).sum().squareRoot())
        }
        dists.sort()
        let radius = dists[min(dists.count - 1, Int(Float(dists.count) * 0.9))]
        return (center, max(radius, 1e-3))
    }
}

public enum SphericalHarmonics {
    /// Y_0^0 coefficient used by 3DGS to map the DC SH term to RGB.
    public static let c0: Float = 0.28209479177387814

    public static func dcToColor(_ dc: Float) -> Float { 0.5 + c0 * dc }
    public static func colorToDC(_ color: Float) -> Float { (color - 0.5) / c0 }
}

@inline(__always) func sigmoid(_ x: Float) -> Float { 1 / (1 + exp(-x)) }
@inline(__always) func inverseSigmoid(_ y: Float) -> Float {
    let c = min(max(y, 1e-6), 1 - 1e-6)
    return log(c / (1 - c))
}
