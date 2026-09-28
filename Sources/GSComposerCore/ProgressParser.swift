import Foundation

/// Extracts progress (0...1) from tool output lines.
public enum ProgressParser {
    /// COLMAP prints `[i/n]` counters, e.g. `Processed file [12/150]`, `Matching image [3/150]`,
    /// `Matching block [2/4, 1/4]`, `Undistorting image [5/150]`.
    public static func colmapFraction(_ line: String) -> Double? {
        let pairs = bracketPairs(line)
        guard let first = pairs.first, first.1 > 0 else { return nil }
        if pairs.count >= 2, pairs[1].1 > 0 {
            let (a, na) = first, (b, nb) = pairs[1]
            return min(1, Double((a - 1) * nb + b) / Double(na * nb))
        }
        return min(1, Double(first.0) / Double(first.1))
    }

    /// COLMAP mapper: `Registering image #12 (13)` — the parenthesised value is the number registered so far.
    public static func mapperRegisteredCount(_ line: String) -> Int? {
        guard let r = line.range(of: "Registering image #") else { return nil }
        let rest = line[r.upperBound...]
        guard let open = rest.firstIndex(of: "("), let close = rest[open...].firstIndex(of: ")") else { return nil }
        return Int(rest[rest.index(after: open)..<close].trimmingCharacters(in: .whitespaces))
    }

    /// Training step from trainer logs.
    /// OpenSplat: `Step 1200: 0.0312 [4%]`; Brush and others: `step 1200/30000`, `Step: 1200`, `iter 1200`.
    public static func trainingStep(_ line: String) -> Int? {
        let lower = line.lowercased()
        for key in ["step", "iter"] {
            var searchStart = lower.startIndex
            while let r = lower.range(of: key, range: searchStart..<lower.endIndex) {
                var i = r.upperBound
                // Skip plural / suffix letters ("steps", "iteration") and separators.
                while i < lower.endIndex, lower[i].isLetter { i = lower.index(after: i) }
                while i < lower.endIndex, lower[i] == " " || lower[i] == ":" || lower[i] == "=" || lower[i] == "#" {
                    i = lower.index(after: i)
                }
                var digits = ""
                while i < lower.endIndex, lower[i].isASCII, lower[i].isNumber { digits.append(lower[i]); i = lower.index(after: i) }
                if let v = Int(digits) { return v }
                searchStart = r.upperBound
            }
        }
        return nil
    }

    static func bracketPairs(_ line: String) -> [(Int, Int)] {
        guard let open = line.lastIndex(of: "["), let close = line[open...].firstIndex(of: "]") else { return [] }
        let inner = line[line.index(after: open)..<close]
        return inner.split(separator: ",").compactMap { part in
            let nums = part.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            guard nums.count == 2, let a = Int(nums[0]), let b = Int(nums[1]) else { return nil }
            return (a, b)
        }
    }
}
