import Foundation

public enum PipelineEvent: Sendable {
    case stageStarted(PipelineStage)
    /// `fraction` is nil when progress is indeterminate.
    case stageProgress(PipelineStage, fraction: Double?, detail: String?)
    case stageFinished(PipelineStage, summary: String?)
    case command(String)
    case log(String, OutputStream)
    /// A new intermediate (or final) splat is available for preview.
    case preview(URL, step: Int?)
}

public struct PipelineTools: Sendable {
    public var colmap: URL
    public var glomap: URL?
    public var trainer: URL

    public init(colmap: URL, glomap: URL?, trainer: URL) {
        self.colmap = colmap
        self.glomap = glomap
        self.trainer = trainer
    }
}

public enum PipelineError: Error, LocalizedError, Equatable {
    case notEnoughImages(Int)
    case reconstructionFailed
    case tooFewRegistered(registered: Int, total: Int)
    case knownPosesFailed(String)
    case noTrainingOutput

    public var errorDescription: String? {
        switch self {
        case .notEnoughImages(let n):
            return "画像が \(n) 枚しかありません。最低 3 枚（推奨 50 枚以上）必要です。"
        case .reconstructionFailed:
            return "COLMAP がカメラ姿勢を推定できませんでした。重なりの多い写真・ブレの少ない動画を使うか、マッチング方式を変更してください。"
        case .tooFewRegistered(let r, let t):
            return "カメラ姿勢を推定できたのは \(t) 枚中 \(r) 枚のみでした。撮影し直すか、設定を見直してください。"
        case .knownPosesFailed(let reason):
            return "ARKit のカメラ姿勢を使った復元に失敗しました: \(reason)"
        case .noTrainingOutput:
            return "学習結果の PLY が見つかりませんでした。ログを確認してください。"
        }
    }
}

/// Runs COLMAP SfM and a 3DGS trainer over images already placed in `workspace.images`.
public final class ReconstructionPipeline: @unchecked Sendable {
    public let workspace: Workspace
    public let settings: PipelineSettings
    public let tools: PipelineTools
    public let input: InputKind
    public let runner: ProcessRunner
    /// Camera poses recorded on the phone (ARKit). When set, matching uses pose-based pairs and SfM is replaced
    /// by triangulation with the poses fixed, which works even where COLMAP cannot register the frames itself.
    public let knownPoses: KnownPoses?

    public init(workspace: Workspace, settings: PipelineSettings, tools: PipelineTools, input: InputKind, runner: ProcessRunner,
                knownPoses: KnownPoses? = nil) {
        self.workspace = workspace
        self.settings = settings
        self.tools = tools
        self.input = input
        self.runner = runner
        self.knownPoses = knownPoses
    }

    public func probeColmap() async -> ColmapCapabilities {
        @Sendable func help(_ args: [String]) async -> String {
            await runner.capture(ToolCommand(executable: tools.colmap, arguments: args))
        }
        async let commands = help(["help"])
        async let fe = help(["feature_extractor", "-h"])
        async let sm = help(["sequential_matcher", "-h"])
        async let em = help(["exhaustive_matcher", "-h"])
        async let mp = help(["mapper", "-h"])
        async let gm = help(["global_mapper", "-h"])
        async let ud = help(["image_undistorter", "-h"])
        async let mi = help(["matches_importer", "-h"])
        async let pt = help(["point_triangulator", "-h"])
        async let ba = help(["bundle_adjuster", "-h"])
        return await ColmapCapabilities(
            commands: ColmapCapabilities.parseCommandList(commands),
            featureExtractor: ColmapOptionSet(helpText: fe),
            sequentialMatcher: ColmapOptionSet(helpText: sm),
            exhaustiveMatcher: ColmapOptionSet(helpText: em),
            mapper: ColmapOptionSet(helpText: mp),
            globalMapper: ColmapOptionSet(helpText: gm),
            imageUndistorter: ColmapOptionSet(helpText: ud),
            matchesImporter: ColmapOptionSet(helpText: mi),
            pointTriangulator: ColmapOptionSet(helpText: pt),
            bundleAdjuster: ColmapOptionSet(helpText: ba)
        )
    }

    /// - Parameter start: first stage to run (`.features` for a full run, `.training` to retrain on an existing SfM result).
    /// - Returns: the final PLY in `workspace.output`.
    public func run(from start: PipelineStage = .features, onEvent: @escaping @Sendable (PipelineEvent) -> Void) async throws -> URL {
        try workspace.create()
        let logger = FileLogger(url: workspace.log)
        defer { logger.close() }
        let emit: @Sendable (PipelineEvent) -> Void = { event in
            switch event {
            case .log(let line, _): logger.write(line)
            case .command(let c): logger.write("$ " + c)
            case .stageStarted(let s): logger.write("=== \(s.title) ===")
            case .stageFinished(let s, let summary): logger.write("=== \(s.title) 完了 \(summary ?? "") ===")
            default: break
            }
            onEvent(event)
        }

        let stages = PipelineStage.allCases
        let startIndex = stages.firstIndex(of: max(start, .features)) ?? 1
        try workspace.reset(from: stages[startIndex] == .features ? .features : stages[startIndex])
        // Poses survive in the workspace so later stages can be re-run (e.g. `--from mapping` in the CLI).
        let known: KnownPoses?
        if let knownPoses {
            try JSONEncoder().encode(knownPoses).write(to: workspace.knownPosesFile, options: .atomic)
            known = knownPoses
        } else {
            known = (try? Data(contentsOf: workspace.knownPosesFile)).flatMap { try? JSONDecoder().decode(KnownPoses.self, from: $0) }
        }
        if let known { emit(.log("ARKit のカメラ姿勢 \(known.poses.count) 枚分を使用します（SfM の代わりに三角測量）", .stdout)) }

        let imageCount = workspace.imageFiles().count
        if startIndex <= stages.firstIndex(of: .mapping)!, imageCount < 3 {
            throw PipelineError.notEnoughImages(imageCount)
        }

        var builder: ColmapCommandBuilder?
        if startIndex <= stages.firstIndex(of: .undistortion)! {
            let caps = await probeColmap()
            builder = ColmapCommandBuilder(colmap: tools.colmap, glomap: tools.glomap, capabilities: caps,
                                           settings: settings, workspace: workspace, input: input)
        }

        for stage in stages[startIndex...] {
            try Task.checkCancellation()
            emit(.stageStarted(stage))
            let summary: String?
            switch stage {
            case .prepareImages:
                summary = nil
            case .features:
                try await runColmap(builder!.featureExtraction(knownCamera: known?.camera), stage: stage, emit: emit)
                summary = "\(imageCount) 枚"
            case .matching:
                if let known {
                    let names = workspace.imageFiles().map(\.lastPathComponent)
                    let pairs = KnownPoseModel.pairs(names: names, poses: known.poses)
                    try KnownPoseModel.pairsText(pairs).write(to: workspace.pairsList, atomically: true, encoding: .utf8)
                    try await runColmap(builder!.pairMatching(listPath: workspace.pairsList), stage: stage, emit: emit)
                    summary = "カメラ姿勢から選んだ \(pairs.count) ペア"
                } else {
                    try await runColmap(builder!.matching(), stage: stage, emit: emit)
                    summary = nil
                }
            case .mapping:
                if let known {
                    summary = try await runKnownPoseMapping(builder!, known: known, emit: emit)
                } else {
                    summary = try await runMapping(builder!, imageCount: imageCount, emit: emit)
                }
            case .undistortion:
                summary = try await runUndistortion(builder!, gravityAligned: known != nil, emit: emit)
            case .training:
                summary = try await runTraining(emit: emit)
            case .finalize:
                let url = try finalize()
                emit(.stageFinished(stage, summary: url.lastPathComponent))
                emit(.preview(url, step: nil))
                return url
            }
            emit(.stageFinished(stage, summary: summary))
        }
        throw PipelineError.noTrainingOutput
    }

    private func runColmap(_ command: ToolCommand, stage: PipelineStage, emit: @escaping @Sendable (PipelineEvent) -> Void) async throws {
        emit(.command(command.displayString))
        try await runner.run(command) { line, stream in
            emit(.log(line, stream))
            if let f = ProgressParser.colmapFraction(line) {
                emit(.stageProgress(stage, fraction: f, detail: nil))
            }
        }
    }

    private func runMapping(_ builder: ColmapCommandBuilder, imageCount: Int, emit: @escaping @Sendable (PipelineEvent) -> Void) async throws -> String {
        let command = builder.mapping()
        emit(.command(command.displayString))
        try await runner.run(command) { line, stream in
            emit(.log(line, stream))
            if let n = ProgressParser.mapperRegisteredCount(line) {
                emit(.stageProgress(.mapping, fraction: min(1, Double(n) / Double(max(imageCount, 1))),
                                    detail: "\(n)/\(imageCount) 枚登録"))
            }
        }
        guard let model = ColmapModelSummary.largestModel(in: workspace.sparse) else {
            throw PipelineError.reconstructionFailed
        }
        if model.registeredImageCount < max(3, imageCount / 4) {
            throw PipelineError.tooFewRegistered(registered: model.registeredImageCount, total: imageCount)
        }
        return "\(imageCount) 枚中 \(model.registeredImageCount) 枚登録 / \(model.pointCount) 点"
    }

    /// Fixed ARKit poses → text model with the database's image IDs → `point_triangulator` → `bundle_adjuster`
    /// (best effort; it only removes small tracking drift) → `sparse/0`.
    private func runKnownPoseMapping(_ builder: ColmapCommandBuilder, known: KnownPoses,
                                     emit: @escaping @Sendable (PipelineEvent) -> Void) async throws -> String {
        let query = ToolCommand(executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: [
            "sqlite3", "-separator", "|", workspace.database.path,
            "SELECT image_id, name, camera_id FROM images;",
        ])
        emit(.command(query.displayString))
        let dbImages = KnownPoseModel.parseDatabaseImages(await runner.capture(query))
        guard !dbImages.isEmpty else {
            throw PipelineError.knownPosesFailed("COLMAP のデータベースから画像一覧を読めませんでした（sqlite3 が必要です）")
        }
        let posed = try KnownPoseModel.write(poses: known, databaseImages: dbImages, to: workspace.knownModel)
        guard posed >= 3 else {
            throw PipelineError.knownPosesFailed("姿勢のある画像が \(posed) 枚しかありません")
        }
        emit(.stageProgress(.mapping, fraction: nil, detail: "\(posed) 枚の姿勢を固定して三角測量"))
        try FileManager.default.createDirectory(at: workspace.triangulatedModel, withIntermediateDirectories: true)
        try await runColmap(builder.pointTriangulation(input: workspace.knownModel, output: workspace.triangulatedModel),
                            stage: .mapping, emit: emit)

        let target = workspace.sparse.appendingPathComponent("0", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        do {
            emit(.stageProgress(.mapping, fraction: nil, detail: "バンドル調整で姿勢のずれを補正"))
            try await runColmap(builder.bundleAdjustment(input: workspace.triangulatedModel, output: target), stage: .mapping, emit: emit)
        } catch {
            try Task.checkCancellation()
            emit(.log("バンドル調整に失敗したため、ARKit の姿勢のまま続行します: \(error.localizedDescription)", .stderr))
        }
        if ColmapModelSummary.read(directory: target) == nil {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: workspace.triangulatedModel, to: target)
        }
        guard let model = ColmapModelSummary.read(directory: target) else {
            throw PipelineError.knownPosesFailed("三角測量の結果が見つかりません")
        }
        guard model.pointCount >= 100 else {
            throw PipelineError.knownPosesFailed("3D 点が \(model.pointCount) 個しか作れませんでした。ブレや模様の少なさを確認してください")
        }
        return "ARKit の姿勢 \(posed) 枚 / \(model.pointCount) 点"
    }

    /// - Parameter gravityAligned: the model is already levelled (ARKit poses), so skip `model_orientation_aligner`.
    private func runUndistortion(_ builder: ColmapCommandBuilder, gravityAligned: Bool,
                                 emit: @escaping @Sendable (PipelineEvent) -> Void) async throws -> String? {
        guard let model = ColmapModelSummary.largestModel(in: workspace.sparse) else {
            throw PipelineError.reconstructionFailed
        }
        let aligned = gravityAligned ? nil : try await alignOrientation(builder, model: model.directory, emit: emit)
        let input = aligned ?? model.directory
        try await runColmap(builder.undistortion(model: input), stage: .undistortion, emit: emit)
        try Self.normalizeDatasetLayout(workspace)
        return nil
    }

    /// Levels the model (see `ColmapCommandBuilder.orientationAlignment`). Best effort: on failure the
    /// unaligned model is used, which still trains fine but may appear tilted in viewers.
    private func alignOrientation(_ builder: ColmapCommandBuilder, model: URL,
                                  emit: @escaping @Sendable (PipelineEvent) -> Void) async throws -> URL? {
        guard let command = builder.orientationAlignment(model: model) else {
            emit(.log("この COLMAP には model_orientation_aligner が無いため、向きの補正を省略します", .stderr))
            return nil
        }
        do {
            try FileManager.default.createDirectory(at: workspace.alignedModel, withIntermediateDirectories: true)
            try await runColmap(command, stage: .undistortion, emit: emit)
        } catch {
            try Task.checkCancellation()
            emit(.log("向きの補正に失敗したため、補正なしで続行します: \(error.localizedDescription)", .stderr))
            return nil
        }
        return ColmapModelSummary.read(directory: workspace.alignedModel) != nil ? workspace.alignedModel : nil
    }

    /// `image_undistorter` writes `dataset/sparse/*.bin`; OpenSplat expects `sparse/0/`, Brush accepts either.
    static func normalizeDatasetLayout(_ workspace: Workspace) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: workspace.datasetModel, withIntermediateDirectories: true)
        let items = try fm.contentsOfDirectory(at: workspace.datasetSparse, includingPropertiesForKeys: nil)
        for item in items where ["bin", "txt"].contains(item.pathExtension) {
            let dest = workspace.datasetModel.appendingPathComponent(item.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: item, to: dest)
        }
        // Drop the dense-stereo scaffolding: it is unused and trainers scan the dataset tree for images.
        for extra in ["stereo", "run-colmap-geometric.sh", "run-colmap-photometric.sh"] {
            let url = workspace.dataset.appendingPathComponent(extra)
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        }
    }

    private func runTraining(emit: @escaping @Sendable (PipelineEvent) -> Void) async throws -> String? {
        let command = TrainerCommandBuilder(executable: tools.trainer, settings: settings, workspace: workspace).command()
        emit(.command(command.displayString))
        let total = settings.totalSteps
        let trainer = settings.trainer
        let trainDir = workspace.train

        let watcher = Task {
            var lastSeen: URL?
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let latest = TrainerCommandBuilder.latestExport(in: trainDir, trainer: trainer),
                      latest.url != lastSeen, Self.isStable(latest.url) else { continue }
                lastSeen = latest.url
                emit(.preview(latest.url, step: latest.step))
                if let step = latest.step {
                    emit(.stageProgress(.training, fraction: min(1, Double(step) / Double(total)), detail: "\(step)/\(total) ステップ"))
                }
            }
        }
        defer { watcher.cancel() }

        let started = Date()
        try await runner.run(command) { line, stream in
            emit(.log(line, stream))
            if let step = ProgressParser.trainingStep(line), step <= total {
                emit(.stageProgress(.training, fraction: Double(step) / Double(total), detail: "\(step)/\(total) ステップ"))
            }
        }
        let minutes = Int(Date().timeIntervalSince(started) / 60)
        return "\(total) ステップ / \(minutes) 分"
    }

    /// True when the file size is unchanged over a short interval (the trainer finished writing it).
    static func isStable(_ url: URL) -> Bool {
        func size() -> Int64? {
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        }
        guard let a = size(), a > 0 else { return false }
        usleep(300_000)
        return size() == a
    }

    private func finalize() throws -> URL {
        guard let latest = TrainerCommandBuilder.latestExport(in: workspace.train, trainer: settings.trainer) else {
            throw PipelineError.noTrainingOutput
        }
        let dest = workspace.output.appendingPathComponent("scene.ply")
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: latest.url, to: dest)
        return dest
    }
}

extension PipelineStage: Comparable {
    public static func < (lhs: PipelineStage, rhs: PipelineStage) -> Bool {
        let all = PipelineStage.allCases
        return all.firstIndex(of: lhs)! < all.firstIndex(of: rhs)!
    }
}

final class FileLogger: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?

    init(url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    func write(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        try? handle?.write(contentsOf: Data((line + "\n").utf8))
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        try? handle?.close()
        handle = nil
    }
}
