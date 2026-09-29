import Foundation

public struct ToolCommand: Equatable, Sendable {
    public var executable: URL
    public var arguments: [String]
    public var workingDirectory: URL?

    public init(executable: URL, arguments: [String], workingDirectory: URL? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
    }

    /// Shell-quoted rendering for logs ("copy as command").
    public var displayString: String {
        ([executable.path] + arguments).map(Self.quote).joined(separator: " ")
    }

    static func quote(_ s: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./=:,+@%{}"))
        if !s.isEmpty, s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Option names accepted by the installed COLMAP, parsed from `colmap <command> -h`.
/// COLMAP renamed several options across releases (e.g. `SiftExtraction.use_gpu` → `FeatureExtraction.use_gpu`),
/// so commands are built against what the binary actually supports.
public struct ColmapOptionSet: Equatable, Sendable {
    public var names: Set<String>

    public init(names: Set<String>) { self.names = names }

    public init(helpText: String) {
        var found = Set<String>()
        let scalars = Array(helpText.unicodeScalars)
        var i = 0
        while i + 1 < scalars.count {
            if scalars[i] == "-", scalars[i + 1] == "-" {
                var j = i + 2
                var name = ""
                while j < scalars.count {
                    let c = scalars[j]
                    if CharacterSet.alphanumerics.contains(c) || c == "_" || c == "." { name.unicodeScalars.append(c); j += 1 } else { break }
                }
                if !name.isEmpty { found.insert(name.trimmingCharacters(in: CharacterSet(charactersIn: "."))) }
                i = j
            } else {
                i += 1
            }
        }
        names = found
    }

    public func first(of candidates: [String]) -> String? {
        candidates.first { names.contains($0) }
    }

    /// `["--name", value]` for the first supported candidate, or `[]` if none is supported.
    public func argument(_ candidates: [String], _ value: String) -> [String] {
        guard let name = first(of: candidates) else { return [] }
        return ["--\(name)", value]
    }
}

/// Commands listed by `colmap help`.
public struct ColmapCapabilities: Equatable, Sendable {
    public var commands: Set<String>
    public var featureExtractor: ColmapOptionSet
    public var sequentialMatcher: ColmapOptionSet
    public var exhaustiveMatcher: ColmapOptionSet
    public var mapper: ColmapOptionSet
    public var globalMapper: ColmapOptionSet
    public var imageUndistorter: ColmapOptionSet

    public init(commands: Set<String>, featureExtractor: ColmapOptionSet, sequentialMatcher: ColmapOptionSet,
                exhaustiveMatcher: ColmapOptionSet, mapper: ColmapOptionSet, globalMapper: ColmapOptionSet,
                imageUndistorter: ColmapOptionSet) {
        self.commands = commands
        self.featureExtractor = featureExtractor
        self.sequentialMatcher = sequentialMatcher
        self.exhaustiveMatcher = exhaustiveMatcher
        self.mapper = mapper
        self.globalMapper = globalMapper
        self.imageUndistorter = imageUndistorter
    }

    public static func parseCommandList(_ helpText: String) -> Set<String> {
        var result = Set<String>()
        for line in helpText.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, !t.contains(" "),
                  t.unicodeScalars.allSatisfy({ CharacterSet.lowercaseLetters.contains($0) || $0 == "_" || CharacterSet.decimalDigits.contains($0) })
            else { continue }
            result.insert(t)
        }
        return result
    }

    public var supportsGlobalMapper: Bool { commands.contains("global_mapper") }
}

public struct ColmapCommandBuilder: Sendable {
    public var colmap: URL
    public var glomap: URL?
    public var capabilities: ColmapCapabilities
    public var settings: PipelineSettings
    public var workspace: Workspace
    public var input: InputKind

    public init(colmap: URL, glomap: URL?, capabilities: ColmapCapabilities, settings: PipelineSettings,
                workspace: Workspace, input: InputKind) {
        self.colmap = colmap
        self.glomap = glomap
        self.capabilities = capabilities
        self.settings = settings
        self.workspace = workspace
        self.input = input
    }

    private var gpuFlag: String { settings.useGPUForSIFT ? "1" : "0" }

    public func featureExtraction() -> ToolCommand {
        let o = capabilities.featureExtractor
        var args = [
            "feature_extractor",
            "--database_path", workspace.database.path,
            "--image_path", workspace.images.path,
            "--ImageReader.camera_model", settings.cameraModel.rawValue,
            "--ImageReader.single_camera", settings.singleCamera ? "1" : "0",
        ]
        args += o.argument(["FeatureExtraction.use_gpu", "SiftExtraction.use_gpu"], gpuFlag)
        args += o.argument(["FeatureExtraction.max_image_size", "SiftExtraction.max_image_size"], String(settings.maxImageSize))
        args += o.argument(["SiftExtraction.max_num_features", "FeatureExtraction.max_num_features"], String(settings.maxFeatures))
        return ToolCommand(executable: colmap, arguments: args)
    }

    public func matching() -> ToolCommand {
        switch settings.resolvedMatcher(for: input) {
        case .sequential, .automatic:
            let o = capabilities.sequentialMatcher
            var args = ["sequential_matcher", "--database_path", workspace.database.path]
            args += o.argument(["FeatureMatching.use_gpu", "SiftMatching.use_gpu"], gpuFlag)
            args += o.argument(["SequentialMatching.overlap"], String(settings.sequentialOverlap))
            args += o.argument(["SequentialMatching.quadratic_overlap"], "1")
            return ToolCommand(executable: colmap, arguments: args)
        case .exhaustive:
            let o = capabilities.exhaustiveMatcher
            var args = ["exhaustive_matcher", "--database_path", workspace.database.path]
            args += o.argument(["FeatureMatching.use_gpu", "SiftMatching.use_gpu"], gpuFlag)
            return ToolCommand(executable: colmap, arguments: args)
        }
    }

    public func mapping() -> ToolCommand {
        let common = ["--database_path", workspace.database.path,
                      "--image_path", workspace.images.path,
                      "--output_path", workspace.sparse.path]
        switch settings.mapper {
        case .glomap:
            if let glomap { return ToolCommand(executable: glomap, arguments: ["mapper"] + common) }
            fallthrough
        case .global:
            if capabilities.supportsGlobalMapper {
                return ToolCommand(executable: colmap, arguments: ["global_mapper"] + common)
            }
            fallthrough
        case .incremental:
            var args = ["mapper"] + common
            let o = capabilities.mapper
            // Frames from one camera: refine the shared intrinsics but keep the principal point fixed.
            args += o.argument(["Mapper.ba_refine_principal_point"], "0")
            args += o.argument(["Mapper.multiple_models"], "1")
            return ToolCommand(executable: colmap, arguments: args)
        }
    }

    public func undistortion(model: URL) -> ToolCommand {
        var args = [
            "image_undistorter",
            "--image_path", workspace.images.path,
            "--input_path", model.path,
            "--output_path", workspace.dataset.path,
            "--output_type", "COLMAP",
        ]
        args += capabilities.imageUndistorter.argument(["max_image_size"], String(settings.maxImageSize))
        return ToolCommand(executable: colmap, arguments: args)
    }
}

public struct TrainerCommandBuilder: Sendable {
    public var executable: URL
    public var settings: PipelineSettings
    public var workspace: Workspace

    public init(executable: URL, settings: PipelineSettings, workspace: Workspace) {
        self.executable = executable
        self.settings = settings
        self.workspace = workspace
    }

    public func command() -> ToolCommand {
        var args: [String]
        switch settings.trainer {
        case .brush:
            args = [
                workspace.dataset.path,
                "--total-steps", String(settings.totalSteps),
                "--max-resolution", String(settings.maxImageSize),
                "--sh-degree", String(settings.shDegree),
                "--max-splats", String(settings.maxSplats),
                "--export-every", String(settings.exportEvery),
                "--export-path", workspace.train.path,
                "--export-name", "export_{iter}.ply",
                "--eval-every", String(max(settings.totalSteps, 1)),
            ]
        case .opensplat:
            args = [
                workspace.dataset.path,
                "-n", String(settings.totalSteps),
                "-o", workspace.train.appendingPathComponent("splat.ply").path,
                "-s", String(settings.exportEvery),
                "--sh-degree", String(max(settings.shDegree, 1)),
                "--max-gaussians", String(settings.maxSplats),
            ]
        }
        args += splitArguments(settings.extraTrainerArguments)
        return ToolCommand(executable: executable, arguments: args, workingDirectory: workspace.train)
    }

    /// Parses the training step from an intermediate export filename.
    /// Brush: `export_7000.ply`; OpenSplat: `splat_7000.ply`.
    public static func step(fromExportName name: String) -> Int? {
        guard name.hasSuffix(".ply") else { return nil }
        let stem = name.dropLast(4)
        guard let underscore = stem.lastIndex(of: "_") else { return nil }
        return Int(stem[stem.index(after: underscore)...])
    }

    /// The most-trained PLY in the train directory. OpenSplat's final `splat.ply` wins over intermediates.
    public static func latestExport(in directory: URL, trainer: TrainerKind) -> (url: URL, step: Int?)? {
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let plys = items.filter { $0.pathExtension.lowercased() == "ply" }
        if trainer == .opensplat, let final = plys.first(where: { $0.lastPathComponent == "splat.ply" }) {
            return (final, nil)
        }
        let stepped = plys.compactMap { url in step(fromExportName: url.lastPathComponent).map { (url, $0) } }
        if let best = stepped.max(by: { $0.1 < $1.1 }) { return (best.0, best.1) }
        return plys.first.map { ($0, nil) }
    }
}
