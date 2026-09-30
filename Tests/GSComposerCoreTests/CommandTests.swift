import XCTest
@testable import GSComposerCore

final class CommandTests: XCTestCase {
    let workspace = Workspace(root: URL(fileURLWithPath: "/tmp/ws", isDirectory: true))
    let colmap = URL(fileURLWithPath: "/opt/homebrew/bin/colmap")

    func capabilities(newNames: Bool, globalMapper: Bool = false) -> ColmapCapabilities {
        let prefix = newNames ? "FeatureExtraction" : "SiftExtraction"
        let matchPrefix = newNames ? "FeatureMatching" : "SiftMatching"
        let fe = ColmapOptionSet(helpText: """
          --database_path arg
          --\(prefix).use_gpu arg (=1)
          --\(prefix).max_image_size arg (=3200)
          --SiftExtraction.max_num_features arg (=8192)
        """)
        let sm = ColmapOptionSet(helpText: "--\(matchPrefix).use_gpu arg\n--SequentialMatching.overlap arg (=10)\n--SequentialMatching.quadratic_overlap arg")
        return ColmapCapabilities(
            commands: globalMapper ? ["mapper", "global_mapper"] : ["mapper"],
            featureExtractor: fe, sequentialMatcher: sm,
            exhaustiveMatcher: ColmapOptionSet(helpText: "--\(matchPrefix).use_gpu arg"),
            mapper: ColmapOptionSet(helpText: "--Mapper.ba_refine_principal_point arg\n--Mapper.multiple_models arg"),
            globalMapper: ColmapOptionSet(helpText: ""),
            imageUndistorter: ColmapOptionSet(helpText: "--max_image_size arg (=-1)"))
    }

    func testOptionSetParsesHelp() {
        let o = ColmapOptionSet(helpText: "  -h [ --help ]\n  --database_path arg\n  --SiftExtraction.use_gpu arg (=1)")
        XCTAssertTrue(o.names.contains("SiftExtraction.use_gpu"))
        XCTAssertTrue(o.names.contains("database_path"))
        XCTAssertEqual(o.argument(["FeatureExtraction.use_gpu", "SiftExtraction.use_gpu"], "0"), ["--SiftExtraction.use_gpu", "0"])
        XCTAssertEqual(o.argument(["Missing.option"], "1"), [])
    }

    func testFeatureExtractionAdaptsToOptionNames() {
        let settings = PipelineSettings()
        for newNames in [false, true] {
            let b = ColmapCommandBuilder(colmap: colmap, glomap: nil, capabilities: capabilities(newNames: newNames),
                                         settings: settings, workspace: workspace, input: .video)
            let args = b.featureExtraction().arguments
            let prefix = newNames ? "FeatureExtraction" : "SiftExtraction"
            XCTAssertEqual(args.first, "feature_extractor")
            XCTAssertTrue(args.contains("--\(prefix).use_gpu"))
            XCTAssertTrue(args.contains("--\(prefix).max_image_size"))
            XCTAssertEqual(args[args.firstIndex(of: "--image_path")! + 1], "/tmp/ws/images")
        }
    }

    func testMatcherChoiceFollowsInputKind() {
        let settings = PipelineSettings()
        let caps = capabilities(newNames: true)
        let video = ColmapCommandBuilder(colmap: colmap, glomap: nil, capabilities: caps, settings: settings, workspace: workspace, input: .video)
        let photos = ColmapCommandBuilder(colmap: colmap, glomap: nil, capabilities: caps, settings: settings, workspace: workspace, input: .photos)
        XCTAssertEqual(video.matching().arguments.first, "sequential_matcher")
        XCTAssertTrue(video.matching().arguments.contains("--FeatureMatching.use_gpu"))
        XCTAssertEqual(photos.matching().arguments.first, "exhaustive_matcher")
    }

    func testMapperFallbacks() {
        var settings = PipelineSettings()
        settings.mapper = .glomap
        let glomap = URL(fileURLWithPath: "/usr/local/bin/glomap")
        let withGlomap = ColmapCommandBuilder(colmap: colmap, glomap: glomap, capabilities: capabilities(newNames: true),
                                              settings: settings, workspace: workspace, input: .photos)
        XCTAssertEqual(withGlomap.mapping().executable, glomap)
        let noGlomapButGlobal = ColmapCommandBuilder(colmap: colmap, glomap: nil, capabilities: capabilities(newNames: true, globalMapper: true),
                                                     settings: settings, workspace: workspace, input: .photos)
        XCTAssertEqual(noGlomapButGlobal.mapping().arguments.first, "global_mapper")
        let neither = ColmapCommandBuilder(colmap: colmap, glomap: nil, capabilities: capabilities(newNames: true),
                                           settings: settings, workspace: workspace, input: .photos)
        XCTAssertEqual(neither.mapping().arguments.first, "mapper")
        XCTAssertTrue(neither.mapping().arguments.contains("--Mapper.multiple_models"))
    }

    func testOrientationAlignment() throws {
        var caps = capabilities(newNames: true)
        let model = workspace.sparse.appendingPathComponent("0")
        let unsupported = ColmapCommandBuilder(colmap: colmap, glomap: nil, capabilities: caps,
                                               settings: PipelineSettings(), workspace: workspace, input: .video)
        XCTAssertNil(unsupported.orientationAlignment(model: model))

        caps.commands.insert("model_orientation_aligner")
        let builder = ColmapCommandBuilder(colmap: colmap, glomap: nil, capabilities: caps,
                                           settings: PipelineSettings(), workspace: workspace, input: .video)
        let command = try XCTUnwrap(builder.orientationAlignment(model: model))
        XCTAssertEqual(command.arguments, [
            "model_orientation_aligner",
            "--image_path", workspace.images.path,
            "--input_path", model.path,
            "--output_path", workspace.alignedModel.path,
            "--method", "IMAGE-ORIENTATION",
        ])
    }

    func testTrainerCommands() {
        var settings = PipelineSettings()
        settings.apply(.preview)
        settings.extraTrainerArguments = "--lr-mean 1e-5"
        let brush = TrainerCommandBuilder(executable: URL(fileURLWithPath: "/x/brush_app"), settings: settings, workspace: workspace).command()
        XCTAssertEqual(brush.arguments.first, "/tmp/ws/dataset")
        XCTAssertEqual(brush.arguments[brush.arguments.firstIndex(of: "--total-steps")! + 1], "7000")
        XCTAssertEqual(Array(brush.arguments.suffix(2)), ["--lr-mean", "1e-5"])

        settings.trainer = .opensplat
        settings.extraTrainerArguments = ""
        let os = TrainerCommandBuilder(executable: URL(fileURLWithPath: "/x/opensplat"), settings: settings, workspace: workspace).command()
        XCTAssertEqual(os.arguments[os.arguments.firstIndex(of: "-n")! + 1], "7000")
        XCTAssertEqual(os.arguments[os.arguments.firstIndex(of: "-o")! + 1], "/tmp/ws/train/splat.ply")
    }

    func testDisplayStringQuotes() {
        let c = ToolCommand(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["a b", "it's"])
        XCTAssertEqual(c.displayString, #"/bin/echo 'a b' 'it'\''s'"#)
    }
}

final class WorkspaceTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gsc-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func writeCount(_ n: UInt64, to url: URL) throws {
        var le = n.littleEndian
        try Data(bytes: &le, count: 8).write(to: url)
    }

    func testLargestModelAndReset() throws {
        let ws = Workspace(root: root)
        try ws.create()
        for (name, images, points) in [("0", 10, 500), ("1", 30, 100), ("2", 30, 200)] {
            let dir = ws.sparse.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try writeCount(1, to: dir.appendingPathComponent("cameras.bin"))
            try writeCount(UInt64(images), to: dir.appendingPathComponent("images.bin"))
            try writeCount(UInt64(points), to: dir.appendingPathComponent("points3D.bin"))
        }
        let best = try XCTUnwrap(ColmapModelSummary.largestModel(in: ws.sparse))
        XCTAssertEqual(best.directory.lastPathComponent, "2")
        XCTAssertEqual(best.registeredImageCount, 30)

        try Data([1]).write(to: ws.images.appendingPathComponent("b.JPG"))
        try Data([1]).write(to: ws.images.appendingPathComponent("a.png"))
        try Data([1]).write(to: ws.images.appendingPathComponent("notes.txt"))
        XCTAssertEqual(ws.imageFiles().map(\.lastPathComponent), ["a.png", "b.JPG"])

        try FileManager.default.createDirectory(at: ws.alignedModel, withIntermediateDirectories: true)
        try ws.reset(from: .mapping)
        XCTAssertNil(ColmapModelSummary.largestModel(in: ws.sparse))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ws.alignedModel.path))
        XCTAssertEqual(ws.imageFiles().count, 2)
    }

    func testDatasetLayoutNormalization() throws {
        let ws = Workspace(root: root)
        try ws.create()
        try FileManager.default.createDirectory(at: ws.datasetSparse, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ws.dataset.appendingPathComponent("stereo"), withIntermediateDirectories: true)
        for f in ["cameras.bin", "images.bin", "points3D.bin"] {
            try Data([0]).write(to: ws.datasetSparse.appendingPathComponent(f))
        }
        try ReconstructionPipeline.normalizeDatasetLayout(ws)
        let moved = try FileManager.default.contentsOfDirectory(atPath: ws.datasetModel.path).sorted()
        XCTAssertEqual(moved, ["cameras.bin", "images.bin", "points3D.bin"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: ws.dataset.appendingPathComponent("stereo").path))
    }

    func testLatestExport() throws {
        let ws = Workspace(root: root)
        try ws.create()
        for n in ["export_500.ply", "export_1500.ply", "export_1000.ply", "other.txt"] {
            try Data([0]).write(to: ws.train.appendingPathComponent(n))
        }
        let latest = try XCTUnwrap(TrainerCommandBuilder.latestExport(in: ws.train, trainer: .brush))
        XCTAssertEqual(latest.url.lastPathComponent, "export_1500.ply")
        XCTAssertEqual(latest.step, 1500)
    }

    func testImageImportRenamesSequentially() throws {
        let src = root.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        for n in ["z.jpeg", "a.PNG", "skip.mov"] { try Data([0]).write(to: src.appendingPathComponent(n)) }
        let ws = Workspace(root: root.appendingPathComponent("ws", isDirectory: true))
        XCTAssertEqual(try ImageImport.copyImages(from: [src], into: ws), 2)
        XCTAssertEqual(ws.imageFiles().map(\.lastPathComponent), ["img_00000.png", "img_00001.jpg"])
    }

    func testProcessRunnerStreamsAndFails() async throws {
        let runner = ProcessRunner()
        let lines = LockedArray()
        let sh = URL(fileURLWithPath: "/bin/sh")
        try await runner.run(ToolCommand(executable: sh, arguments: ["-c", "echo one; echo two >&2"])) { l, _ in lines.append(l) }
        XCTAssertEqual(Set(lines.values), ["one", "two"])
        do {
            try await runner.run(ToolCommand(executable: sh, arguments: ["-c", "echo boom; exit 3"])) { _, _ in }
            XCTFail("expected failure")
        } catch let e as ProcessFailure {
            XCTAssertEqual(e.exitCode, 3)
            XCTAssertEqual(e.lastLines, ["boom"])
        }
    }
}
