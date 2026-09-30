import Foundation

/// On-disk layout of one reconstruction project.
///
/// ```
/// <root>/
///   images/            input frames / photos
///   colmap/database.db
///   colmap/sparse/N/   COLMAP models (the largest is used)
///   colmap/aligned/    largest model rotated so gravity points along +Y
///   colmap/known_poses.json, known/, pairs.txt, triangulated/
///                      ARKit poses: fixed-pose text model and matched pairs (instead of SfM)
///   dataset/           undistorted images + sparse/0 (trainer input)
///   train/             periodic trainer exports
///   output/            final PLY / .splat
///   pipeline.log
/// ```
public struct Workspace: Sendable, Equatable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public var images: URL { root.appendingPathComponent("images", isDirectory: true) }
    public var colmap: URL { root.appendingPathComponent("colmap", isDirectory: true) }
    public var database: URL { colmap.appendingPathComponent("database.db") }
    public var sparse: URL { colmap.appendingPathComponent("sparse", isDirectory: true) }
    public var alignedModel: URL { colmap.appendingPathComponent("aligned", isDirectory: true) }
    public var knownPosesFile: URL { colmap.appendingPathComponent("known_poses.json") }
    public var knownModel: URL { colmap.appendingPathComponent("known", isDirectory: true) }
    public var pairsList: URL { colmap.appendingPathComponent("pairs.txt") }
    public var triangulatedModel: URL { colmap.appendingPathComponent("triangulated", isDirectory: true) }
    public var dataset: URL { root.appendingPathComponent("dataset", isDirectory: true) }
    public var datasetSparse: URL { dataset.appendingPathComponent("sparse", isDirectory: true) }
    public var datasetModel: URL { datasetSparse.appendingPathComponent("0", isDirectory: true) }
    public var train: URL { root.appendingPathComponent("train", isDirectory: true) }
    public var output: URL { root.appendingPathComponent("output", isDirectory: true) }
    public var log: URL { root.appendingPathComponent("pipeline.log") }

    public func create() throws {
        for dir in [images, colmap, sparse, dataset, train, output] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Removes artefacts produced by `stage` and every later stage so it can be re-run cleanly.
    public func reset(from stage: PipelineStage) throws {
        let fm = FileManager.default
        func remove(_ url: URL) throws {
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        }
        let order = PipelineStage.allCases
        guard let start = order.firstIndex(of: stage) else { return }
        for s in order[start...] {
            switch s {
            case .prepareImages:
                try remove(images)
                try remove(knownPosesFile)
            case .features:
                try remove(database)
                for suffix in ["-shm", "-wal"] { try remove(URL(fileURLWithPath: database.path + suffix)) }
            case .matching: try remove(pairsList)
            case .mapping:
                try remove(sparse)
                try remove(knownModel)
                try remove(triangulatedModel)
            case .undistortion:
                try remove(alignedModel)
                try remove(dataset)
            case .training: try remove(train)
            case .finalize: break
            }
        }
        try create()
    }

    public static let imageExtensions: Set<String> = ["jpg", "jpeg", "png"]

    public func imageFiles() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: images, includingPropertiesForKeys: nil)) ?? []
        return items.filter { Workspace.imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
