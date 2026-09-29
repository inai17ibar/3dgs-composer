import Foundation
import GSComposerCore

let usage = """
使い方:
  gscomposer-cli run --images <dir|file...> --workspace <dir> [--preset preview|standard|high]
                     [--trainer brush|opensplat] [--trainer-path <exe>] [--colmap <exe>]
                     [--steps N] [--video] [--from <stage>]
  gscomposer-cli convert <input.ply> <output.splat|output.ply>
  gscomposer-cli info <input.ply>
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func parseOptions(_ args: ArraySlice<String>) -> (options: [String: String], positional: [String], flags: Set<String>) {
    var options: [String: String] = [:]
    var positional: [String] = []
    var flags = Set<String>()
    var it = args.makeIterator()
    let valueless: Set<String> = ["--video"]
    while let a = it.next() {
        if a.hasPrefix("--") {
            if valueless.contains(a) { flags.insert(a); continue }
            guard let v = it.next() else { fail("\(a) に値がありません") }
            if a == "--images" {
                positional.append(v)
            } else {
                options[a] = v
            }
        } else {
            positional.append(a)
        }
    }
    return (options, positional, flags)
}

func runPipeline(_ args: ArraySlice<String>) async {
    let (options, images, flags) = parseOptions(args)
    guard let ws = options["--workspace"] else { fail(usage) }
    let workspace = Workspace(root: URL(fileURLWithPath: ws, isDirectory: true))
    var settings = PipelineSettings()
    if let p = options["--preset"] {
        guard let preset = QualityPreset(rawValue: p) else { fail("不明なプリセット: \(p)") }
        settings.apply(preset)
    }
    if let t = options["--trainer"] {
        guard let trainer = TrainerKind(rawValue: t) else { fail("不明なトレーナー: \(t)") }
        settings.trainer = trainer
    }
    if let s = options["--steps"], let n = Int(s) { settings.totalSteps = n }
    if let extra = options["--trainer-args"] { settings.extraTrainerArguments = extra }
    var start = PipelineStage.features
    if let f = options["--from"] {
        guard let stage = PipelineStage(rawValue: f) else { fail("不明なステージ: \(f)") }
        start = stage
    }

    var overrides: [ExternalTool: URL] = [:]
    if let c = options["--colmap"] { overrides[.colmap] = URL(fileURLWithPath: c) }
    let trainerTool: ExternalTool = settings.trainer == .brush ? .brush : .opensplat
    if let t = options["--trainer-path"] { overrides[trainerTool] = URL(fileURLWithPath: t) }
    let locator = ToolLocator(overrides: overrides)
    guard let colmap = locator.locate(.colmap) else { fail("COLMAP が見つかりません: \(ExternalTool.colmap.installHint)") }
    guard let trainer = locator.locate(trainerTool) else { fail("トレーナーが見つかりません: \(trainerTool.installHint)") }

    do {
        try workspace.create()
        if !images.isEmpty {
            try workspace.reset(from: .prepareImages)
            let n = try ImageImport.copyImages(from: images.map { URL(fileURLWithPath: $0) }, into: workspace)
            print("画像 \(n) 枚を取り込みました")
        }
        let pipeline = ReconstructionPipeline(
            workspace: workspace, settings: settings,
            tools: PipelineTools(colmap: colmap, glomap: locator.locate(.glomap), trainer: trainer),
            input: flags.contains("--video") ? .video : .photos,
            runner: ProcessRunner(path: locator.childPath))
        let verbose = ProcessInfo.processInfo.environment["GSCOMPOSER_VERBOSE"] != nil
        let result = try await pipeline.run(from: start) { event in
            switch event {
            case .stageStarted(let s): print("▶ \(s.title)")
            case .stageFinished(let s, let summary): print("✓ \(s.title) \(summary ?? "")")
            case .command(let c): print("  $ \(c)")
            case .stageProgress(_, let f, let detail):
                if verbose, let f { print(String(format: "  %.0f%% %@", f * 100, detail ?? "")) }
            case .log(let line, _): if verbose { print("    \(line)") }
            case .preview(let url, let step): print("  プレビュー: \(url.lastPathComponent) step=\(step.map(String.init) ?? "-")")
            }
        }
        let cloud = try PLYReader.read(url: result)
        let splat = result.deletingPathExtension().appendingPathExtension("splat")
        try SplatFileWriter.write(cloud, to: splat)
        print("完了: \(result.path) (\(cloud.count) splats), \(splat.lastPathComponent)")
    } catch {
        fail("エラー: \(error.localizedDescription)\nログ: \(workspace.log.path)")
    }
}

func convert(_ args: ArraySlice<String>) {
    let a = Array(args)
    guard a.count == 2 else { fail(usage) }
    do {
        let cloud = try PLYReader.read(url: URL(fileURLWithPath: a[0]))
        let out = URL(fileURLWithPath: a[1])
        switch out.pathExtension.lowercased() {
        case "splat": try SplatFileWriter.write(cloud, to: out)
        case "ply": try GaussianPLYWriter.write(cloud, to: out)
        default: fail("出力拡張子は .splat か .ply にしてください")
        }
        print("\(cloud.count) splats → \(out.path)")
    } catch {
        fail("エラー: \(error.localizedDescription)")
    }
}

func info(_ args: ArraySlice<String>) {
    guard let path = args.first else { fail(usage) }
    do {
        let cloud = try PLYReader.read(url: URL(fileURLWithPath: path))
        let b = cloud.robustBounds()
        print("splats: \(cloud.count)")
        print("center: \(b.center)  radius: \(b.radius)")
    } catch {
        fail("エラー: \(error.localizedDescription)")
    }
}

let argv = CommandLine.arguments.dropFirst()
switch argv.first {
case "run": await runPipeline(argv.dropFirst())
case "convert": convert(argv.dropFirst())
case "info": info(argv.dropFirst())
default: print(usage)
}
