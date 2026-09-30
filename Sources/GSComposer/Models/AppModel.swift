import AppKit
import Foundation
import GSComposerCore
import Observation

enum StageStatus: Equatable {
    case pending, running, done, failed, skipped
}

struct StageState: Identifiable, Equatable {
    let stage: PipelineStage
    var status: StageStatus = .pending
    var fraction: Double?
    var detail: String?

    var id: PipelineStage { stage }
}

struct LogLine: Identifiable {
    let id: Int
    let text: String
    let isError: Bool
    let isCommand: Bool
}

@MainActor
@Observable
final class AppModel {
    // Input
    var inputKind: InputKind = .video
    var inputURLs: [URL] = []
    var projectName = ""

    // Settings
    var preset: QualityPreset = .standard {
        didSet { settings.apply(preset) }
    }
    var settings = PipelineSettings()

    // Run state
    var stages: [StageState] = PipelineStage.allCases.map { StageState(stage: $0) }
    var isRunning = false
    var errorMessage: String?
    var logLines: [LogLine] = []
    var workspace: Workspace?
    var startedAt: Date?

    // Viewer
    var viewerURL: URL?
    var viewerStep: Int?
    var resultURL: URL?

    private var runTask: Task<Void, Never>?
    private var nextLogID = 0
    private static let maxLogLines = 4000

    var canStart: Bool { !isRunning && !inputURLs.isEmpty }

    var canRetrain: Bool {
        guard !isRunning, let ws = workspace else { return false }
        return FileManager.default.fileExists(atPath: ws.datasetModel.appendingPathComponent("cameras.bin").path)
    }

    var inputSummary: String {
        switch inputKind {
        case .video: return inputURLs.first?.lastPathComponent ?? "動画が未選択"
        case .photos: return inputURLs.isEmpty ? "写真が未選択" : "写真 \(inputURLs.count) 枚"
        }
    }

    static var projectsRoot: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("3DGS Composer", isDirectory: true)
    }

    // MARK: Input

    /// Accepts dropped/picked files: one movie → video mode; images/folders → photo mode.
    func setInputs(_ urls: [URL]) {
        if let movie = urls.first(where: PhotoImporter.isMovie) {
            inputKind = .video
            inputURLs = [movie]
            projectName = movie.deletingPathExtension().lastPathComponent
            return
        }
        let photos = PhotoImporter.expand(urls)
        guard !photos.isEmpty else {
            errorMessage = "動画または画像ファイルを選択してください。"
            return
        }
        inputKind = .photos
        inputURLs = photos
        let folder = urls.count == 1 && urls[0].hasDirectoryPath ? urls[0] : photos[0].deletingLastPathComponent()
        projectName = folder.lastPathComponent
    }

    func pickInputs(kind: InputKind) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = kind == .photos
        panel.canChooseDirectories = kind == .photos
        panel.allowedContentTypes = kind == .video ? [.movie] : [.image, .folder]
        panel.message = kind == .video ? "3DGS を作成する動画を選択" : "写真（複数可）またはフォルダを選択"
        if panel.runModal() == .OK { setInputs(panel.urls) }
    }

    // MARK: Run

    func start() {
        guard canStart else { return }
        let locator = ToolPreferences.locator
        guard let colmap = locator.locate(.colmap) else {
            errorMessage = "COLMAP が見つかりません。\n\(ExternalTool.colmap.installHint) でインストールするか、設定でパスを指定してください。"
            return
        }
        let trainerTool: ExternalTool = settings.trainer == .brush ? .brush : .opensplat
        guard let trainer = locator.locate(trainerTool) else {
            errorMessage = "\(settings.trainer.displayName) が見つかりません。\n\(trainerTool.installHint)か、設定でパスを指定してください。"
            return
        }
        let stamp = Self.stampFormatter.string(from: Date())
        let name = projectName.isEmpty ? "Scene" : projectName
        let ws = Workspace(root: Self.projectsRoot.appendingPathComponent("\(name)-\(stamp)", isDirectory: true))
        workspace = ws
        let tools = PipelineTools(colmap: colmap, glomap: locator.locate(.glomap), trainer: trainer)
        launch(workspace: ws, tools: tools, childPath: locator.childPath, from: .prepareImages)
    }

    /// Re-runs only 3DGS training on the existing camera poses (e.g. after changing trainer settings).
    func retrain() {
        guard canRetrain, let ws = workspace else { return }
        let locator = ToolPreferences.locator
        let trainerTool: ExternalTool = settings.trainer == .brush ? .brush : .opensplat
        guard let colmap = locator.locate(.colmap), let trainer = locator.locate(trainerTool) else {
            errorMessage = "ツールが見つかりません。設定を確認してください。"
            return
        }
        launch(workspace: ws, tools: PipelineTools(colmap: colmap, glomap: nil, trainer: trainer),
               childPath: locator.childPath, from: .training)
    }

    func cancel() {
        runTask?.cancel()
    }

    private func launch(workspace ws: Workspace, tools: PipelineTools, childPath: String, from start: PipelineStage) {
        errorMessage = nil
        isRunning = true
        startedAt = Date()
        resultURL = nil
        for i in stages.indices where stages[i].stage >= start {
            stages[i] = StageState(stage: stages[i].stage)
        }
        if start == .prepareImages { logLines.removeAll() }

        let settings = self.settings
        let input = inputKind
        let sources = inputURLs
        let (events, continuation) = AsyncStream<PipelineEvent>.makeStream()

        let consumer = Task { @MainActor [weak self] in
            for await event in events { self?.handle(event) }
        }

        runTask = Task.detached { [weak self] in
            do {
                if start == .prepareImages {
                    continuation.yield(.stageStarted(.prepareImages))
                    try ws.create()
                    try ws.reset(from: .prepareImages)
                    let progress: @Sendable (Double, String) -> Void = { f, d in
                        continuation.yield(.stageProgress(.prepareImages, fraction: f, detail: d))
                    }
                    let count: Int
                    switch input {
                    case .video:
                        count = try await FrameExtractor.extract(
                            video: sources[0], into: ws.images,
                            options: .init(targetCount: settings.targetFrameCount, pickSharpest: settings.pickSharpestFrames,
                                           maxImageSize: settings.maxImageSize),
                            progress: progress)
                    case .photos:
                        count = try await PhotoImporter.importPhotos(sources, into: ws.images, maxImageSize: settings.maxImageSize,
                                                                     progress: progress)
                    }
                    continuation.yield(.stageFinished(.prepareImages, summary: "\(count) 枚"))
                }
                let pipeline = ReconstructionPipeline(workspace: ws, settings: settings, tools: tools, input: input,
                                                      runner: ProcessRunner(path: childPath))
                let result = try await pipeline.run(from: max(start, .features)) { continuation.yield($0) }
                continuation.finish()
                await consumer.value
                await self?.finish(result: result, error: nil)
            } catch {
                continuation.finish()
                await consumer.value
                await self?.finish(result: nil, error: error)
            }
        }
    }

    private func finish(result: URL?, error: Error?) {
        isRunning = false
        runTask = nil
        if let result {
            resultURL = result
            viewerURL = result
            viewerStep = nil
            NSApp.requestUserAttention(.informationalRequest)
            return
        }
        for i in stages.indices where stages[i].status == .running {
            stages[i].status = .failed
        }
        if error is CancellationError || Task.isCancelled {
            appendLog("キャンセルしました", isError: true)
        } else if let error {
            errorMessage = error.localizedDescription
            appendLog(error.localizedDescription, isError: true)
        }
    }

    private func handle(_ event: PipelineEvent) {
        switch event {
        case .stageStarted(let s):
            update(s) { $0.status = .running; $0.fraction = nil; $0.detail = nil }
        case .stageProgress(let s, let f, let d):
            update(s) { st in
                if let f { st.fraction = f }
                if let d { st.detail = d }
            }
        case .stageFinished(let s, let summary):
            update(s) { $0.status = .done; $0.fraction = 1; $0.detail = summary ?? $0.detail }
        case .command(let c):
            appendLog("$ " + c, isCommand: true)
        case .log(let line, let stream):
            appendLog(line, isError: stream == .stderr && line.localizedCaseInsensitiveContains("error"))
        case .preview(let url, let step):
            viewerURL = url
            viewerStep = step
        }
    }

    private func update(_ stage: PipelineStage, _ body: (inout StageState) -> Void) {
        guard let i = stages.firstIndex(where: { $0.stage == stage }) else { return }
        body(&stages[i])
    }

    private func appendLog(_ text: String, isError: Bool = false, isCommand: Bool = false) {
        logLines.append(LogLine(id: nextLogID, text: text, isError: isError, isCommand: isCommand))
        nextLogID += 1
        if logLines.count > Self.maxLogLines { logLines.removeFirst(logLines.count - Self.maxLogLines) }
    }

    // MARK: Files

    func openSplatFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "ply")!, .init(filenameExtension: "splat")!]
        panel.message = "表示する 3DGS ファイル (.ply / .splat) を選択"
        if panel.runModal() == .OK, let url = panel.url {
            viewerURL = url
            viewerStep = nil
        }
    }

    func export(as ext: String) {
        guard let source = resultURL ?? viewerURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: ext)!]
        panel.nameFieldStringValue = (projectName.isEmpty ? "scene" : projectName) + "." + ext
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        Task.detached { [weak self] in
            do {
                let fm = FileManager.default
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                if ext == source.pathExtension.lowercased() {
                    // Keep the trainer's full-SH PLY untouched.
                    try fm.copyItem(at: source, to: dest)
                } else {
                    let cloud = try SplatLoader.load(url: source)
                    if ext == "splat" {
                        try SplatFileWriter.write(cloud, to: dest)
                    } else {
                        try GaussianPLYWriter.write(cloud, to: dest)
                    }
                }
                await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([dest]) }
            } catch {
                await MainActor.run { self?.errorMessage = "書き出しに失敗しました: \(error.localizedDescription)" }
            }
        }
    }

    func revealWorkspace() {
        guard let ws = workspace else { return }
        NSWorkspace.shared.activateFileViewerSelecting([ws.root])
    }

    func openExistingWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = Self.projectsRoot
        panel.message = "以前のプロジェクトフォルダを選択（再学習・表示に使用）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let ws = Workspace(root: url)
        workspace = ws
        projectName = url.lastPathComponent
        let final = ws.output.appendingPathComponent("scene.ply")
        if FileManager.default.fileExists(atPath: final.path) {
            resultURL = final
            viewerURL = final
        } else if let latest = TrainerCommandBuilder.latestExport(in: ws.train, trainer: settings.trainer) {
            viewerURL = latest.url
            viewerStep = latest.step
        }
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
