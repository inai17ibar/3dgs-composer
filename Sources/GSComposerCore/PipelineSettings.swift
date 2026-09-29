import Foundation

public enum PipelineStage: String, CaseIterable, Codable, Sendable, Identifiable {
    case prepareImages, features, matching, mapping, undistortion, training, finalize

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .prepareImages: return "画像の準備"
        case .features: return "特徴点抽出 (COLMAP)"
        case .matching: return "特徴点マッチング (COLMAP)"
        case .mapping: return "カメラ姿勢推定 / SfM (COLMAP)"
        case .undistortion: return "歪み補正 (COLMAP)"
        case .training: return "3DGS 学習"
        case .finalize: return "書き出し"
        }
    }
}

public enum ColmapCameraModel: String, CaseIterable, Codable, Sendable {
    case simpleRadial = "SIMPLE_RADIAL"
    case opencv = "OPENCV"
    case pinhole = "PINHOLE"
    case opencvFisheye = "OPENCV_FISHEYE"

    public var displayName: String {
        switch self {
        case .simpleRadial: return "SIMPLE_RADIAL (スマホ・一般的なカメラ)"
        case .opencv: return "OPENCV (歪み補正あり・推奨)"
        case .pinhole: return "PINHOLE (歪みなし)"
        case .opencvFisheye: return "OPENCV_FISHEYE (魚眼・GoPro 等)"
        }
    }
}

public enum MatcherKind: String, CaseIterable, Codable, Sendable {
    /// Sequential for video frames, exhaustive for photo sets.
    case automatic
    case sequential
    case exhaustive

    public var displayName: String {
        switch self {
        case .automatic: return "自動 (動画=連続 / 写真=総当たり)"
        case .sequential: return "連続 (動画向け・速い)"
        case .exhaustive: return "総当たり (写真向け・高精度)"
        }
    }
}

public enum MapperKind: String, CaseIterable, Codable, Sendable {
    /// `colmap mapper` — slow but most robust.
    case incremental
    /// `colmap global_mapper` (COLMAP 3.13+, formerly GLOMAP) — much faster on large sets.
    case global
    /// Standalone `glomap mapper`.
    case glomap

    public var displayName: String {
        switch self {
        case .incremental: return "Incremental (標準・堅牢)"
        case .global: return "Global (COLMAP 3.13+・高速)"
        case .glomap: return "GLOMAP (別途インストール・高速)"
        }
    }
}

public enum TrainerKind: String, CaseIterable, Codable, Sendable {
    case brush
    case opensplat

    public var displayName: String {
        switch self {
        case .brush: return "Brush (Metal / WebGPU)"
        case .opensplat: return "OpenSplat (MPS)"
        }
    }
}

public enum InputKind: String, Codable, Sendable {
    case video, photos
}

public enum QualityPreset: String, CaseIterable, Codable, Sendable {
    case preview, standard, high

    public var displayName: String {
        switch self {
        case .preview: return "プレビュー (速い)"
        case .standard: return "標準"
        case .high: return "高品質"
        }
    }
}

public struct PipelineSettings: Codable, Equatable, Sendable {
    // Frame extraction (video input)
    public var targetFrameCount: Int = 150
    public var pickSharpestFrames: Bool = true
    /// Longest edge of images handed to COLMAP / the trainer.
    public var maxImageSize: Int = 1600

    // COLMAP
    public var cameraModel: ColmapCameraModel = .opencv
    public var singleCamera: Bool = true
    public var matcher: MatcherKind = .automatic
    public var sequentialOverlap: Int = 12
    public var mapper: MapperKind = .incremental
    public var maxFeatures: Int = 8192
    public var useGPUForSIFT: Bool = false

    // Training
    public var trainer: TrainerKind = .brush
    public var totalSteps: Int = 30_000
    public var shDegree: Int = 3
    public var maxSplats: Int = 3_000_000
    public var exportEvery: Int = 1_000
    /// Extra arguments appended verbatim to the trainer command line.
    public var extraTrainerArguments: String = ""

    public init() {}

    public mutating func apply(_ preset: QualityPreset) {
        switch preset {
        case .preview:
            totalSteps = 7_000; maxImageSize = 1280; maxSplats = 1_000_000; shDegree = 1; exportEvery = 500
        case .standard:
            totalSteps = 30_000; maxImageSize = 1600; maxSplats = 3_000_000; shDegree = 3; exportEvery = 1_000
        case .high:
            totalSteps = 50_000; maxImageSize = 2400; maxSplats = 6_000_000; shDegree = 3; exportEvery = 2_000
        }
    }

    public func resolvedMatcher(for input: InputKind) -> MatcherKind {
        guard matcher == .automatic else { return matcher }
        return input == .video ? .sequential : .exhaustive
    }
}

/// Splits a user-typed argument string, honouring single/double quotes.
public func splitArguments(_ s: String) -> [String] {
    var result: [String] = []
    var current = ""
    var quote: Character?
    var hasToken = false
    for ch in s {
        if let q = quote {
            if ch == q { quote = nil } else { current.append(ch) }
        } else if ch == "\"" || ch == "'" {
            quote = ch; hasToken = true
        } else if ch == " " || ch == "\t" || ch == "\n" {
            if hasToken || !current.isEmpty { result.append(current); current = ""; hasToken = false }
        } else {
            current.append(ch); hasToken = true
        }
    }
    if hasToken || !current.isEmpty { result.append(current) }
    return result
}
