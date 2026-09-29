import Foundation

/// Lightweight inspection of COLMAP binary models (cameras.bin / images.bin / points3D.bin).
public struct ColmapModelSummary: Equatable, Sendable {
    public var directory: URL
    public var cameraCount: Int
    public var registeredImageCount: Int
    public var pointCount: Int

    public static func read(directory: URL) -> ColmapModelSummary? {
        func count(_ name: String) -> Int? {
            let url = directory.appendingPathComponent(name)
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: 8), data.count == 8 else { return nil }
            var value: UInt64 = 0
            for (i, b) in data.enumerated() { value |= UInt64(b) << (8 * UInt64(i)) }
            return Int(UInt64(littleEndian: value))
        }
        guard let images = count("images.bin"), let cameras = count("cameras.bin") else { return nil }
        return ColmapModelSummary(directory: directory, cameraCount: cameras, registeredImageCount: images,
                                  pointCount: count("points3D.bin") ?? 0)
    }

    /// Picks the sub-model with the most registered images (COLMAP may split a scene into several models).
    public static func largestModel(in sparseRoot: URL) -> ColmapModelSummary? {
        var candidates: [URL] = [sparseRoot]
        if let items = try? FileManager.default.contentsOfDirectory(at: sparseRoot, includingPropertiesForKeys: [.isDirectoryKey]) {
            candidates += items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
        return candidates.compactMap(read(directory:))
            .max { a, b in
                a.registeredImageCount != b.registeredImageCount
                    ? a.registeredImageCount < b.registeredImageCount
                    : a.pointCount < b.pointCount
            }
    }
}
