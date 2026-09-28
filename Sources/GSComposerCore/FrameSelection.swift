import Foundation

public enum FrameSelection {
    /// Variance of the 4-neighbour Laplacian of an 8-bit grayscale image — a standard blur metric
    /// (higher is sharper). Motion-blurred video frames hurt both SfM and splat quality.
    public static func laplacianVariance(gray: [UInt8], width: Int, height: Int, bytesPerRow: Int? = nil) -> Double {
        let stride = bytesPerRow ?? width
        guard width >= 3, height >= 3, gray.count >= stride * height else { return 0 }
        var sum = 0.0
        var sumSq = 0.0
        var n = 0.0
        gray.withUnsafeBufferPointer { p in
            for y in 1..<(height - 1) {
                let row = y * stride
                for x in 1..<(width - 1) {
                    let c = Int(p[row + x])
                    let lap = Int(p[row + x - 1]) + Int(p[row + x + 1]) + Int(p[row - stride + x]) + Int(p[row + stride + x]) - 4 * c
                    let v = Double(lap)
                    sum += v
                    sumSq += v * v
                    n += 1
                }
            }
        }
        let mean = sum / n
        return sumSq / n - mean * mean
    }

    /// Evenly spaced sample times over `duration`, centred in each slot.
    public static func sampleTimes(duration: Double, count: Int) -> [Double] {
        guard duration > 0, count > 0 else { return [] }
        let slot = duration / Double(count)
        return (0..<count).map { (Double($0) + 0.5) * slot }
    }

    /// Splits the candidates into `targetCount` consecutive groups and keeps the sharpest of each,
    /// so coverage stays uniform over time while blurry frames are skipped.
    /// - Returns: indices into `scores`, ascending.
    public static func pickSharpest(scores: [Double], targetCount: Int) -> [Int] {
        guard !scores.isEmpty, targetCount > 0 else { return [] }
        if targetCount >= scores.count { return Array(scores.indices) }
        var picked: [Int] = []
        for g in 0..<targetCount {
            let lo = g * scores.count / targetCount
            let hi = (g + 1) * scores.count / targetCount
            guard lo < hi else { continue }
            var best = lo
            for i in lo..<hi where scores[i] > scores[best] { best = i }
            picked.append(best)
        }
        return picked
    }
}
