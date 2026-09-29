import Foundation

/// Back-to-front ordering for alpha-blended splat rendering.
/// Uses a 16-bit counting sort over view-space depth (O(n), ~10 ms for 1M splats on Apple silicon).
public enum DepthSorter {
    /// - Parameters:
    ///   - positions: flat xyz array.
    ///   - cameraPosition: eye position in world space.
    ///   - forward: unit view direction in world space.
    /// - Returns: splat indices ordered from farthest to nearest.
    public static func backToFront(positions: [Float], cameraPosition: SIMD3<Float>, forward: SIMD3<Float>) -> [UInt32] {
        let n = positions.count / 3
        guard n > 0 else { return [] }
        var depths = [Float](repeating: 0, count: n)
        var minD = Float.greatestFiniteMagnitude
        var maxD = -Float.greatestFiniteMagnitude
        positions.withUnsafeBufferPointer { p in
            for i in 0..<n {
                let d = (p[i * 3] - cameraPosition.x) * forward.x
                    + (p[i * 3 + 1] - cameraPosition.y) * forward.y
                    + (p[i * 3 + 2] - cameraPosition.z) * forward.z
                depths[i] = d
                if d < minD { minD = d }
                if d > maxD { maxD = d }
            }
        }
        let bucketCount = 1 << 16
        let range = maxD - minD
        let scale = range > 0 ? Float(bucketCount - 1) / range : 0
        var keys = [UInt16](repeating: 0, count: n)
        var counts = [Int](repeating: 0, count: bucketCount)
        for i in 0..<n {
            // Farther splats get smaller keys so they are drawn first.
            let k = UInt16(clamping: Int((maxD - depths[i]) * scale))
            keys[i] = k
            counts[Int(k)] += 1
        }
        var running = 0
        for b in 0..<bucketCount {
            let c = counts[b]
            counts[b] = running
            running += c
        }
        var order = [UInt32](repeating: 0, count: n)
        for i in 0..<n {
            let k = Int(keys[i])
            order[counts[k]] = UInt32(i)
            counts[k] += 1
        }
        return order
    }
}
