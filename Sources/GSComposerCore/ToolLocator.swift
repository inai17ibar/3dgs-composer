import Foundation

public enum ExternalTool: String, CaseIterable, Codable, Sendable {
    case colmap, glomap, brush, opensplat, ffmpeg

    public var executableNames: [String] {
        switch self {
        case .colmap: return ["colmap"]
        case .glomap: return ["glomap"]
        case .brush: return ["brush_app", "brush"]
        case .opensplat: return ["opensplat"]
        case .ffmpeg: return ["ffmpeg"]
        }
    }

    public var installHint: String {
        switch self {
        case .colmap: return "brew install colmap"
        case .glomap: return "brew install glomap（任意）"
        case .brush: return "https://github.com/ArthurBrussee/brush/releases から brush-app-aarch64-apple-darwin.tar.xz を入手し、中の brush_app を ~/.local/bin に置く"
        case .opensplat: return "https://github.com/pierotofy/OpenSplat をビルドする"
        case .ffmpeg: return "brew install ffmpeg"
        }
    }
}

public struct ToolLocator: Sendable {
    public var overrides: [ExternalTool: URL]
    public var searchDirectories: [URL]

    public static var defaultSearchDirectories: [URL] {
        var dirs: [URL] = []
        let env = ProcessInfo.processInfo.environment["PATH"] ?? ""
        dirs += env.split(separator: ":").map { URL(fileURLWithPath: String($0), isDirectory: true) }
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/opt/local/bin"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        dirs.append(home.appendingPathComponent(".local/bin", isDirectory: true))
        dirs.append(home.appendingPathComponent("bin", isDirectory: true))
        var seen = Set<String>()
        return dirs.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    public init(overrides: [ExternalTool: URL] = [:], searchDirectories: [URL] = ToolLocator.defaultSearchDirectories) {
        self.overrides = overrides
        self.searchDirectories = searchDirectories
    }

    public func locate(_ tool: ExternalTool) -> URL? {
        let fm = FileManager.default
        if let o = overrides[tool] {
            return fm.isExecutableFile(atPath: o.path) ? o : nil
        }
        for dir in searchDirectories {
            for name in tool.executableNames {
                let url = dir.appendingPathComponent(name)
                if fm.isExecutableFile(atPath: url.path) { return url }
            }
        }
        return nil
    }

    /// PATH for child processes: COLMAP/Brush may shell out or load dylibs from Homebrew.
    public var childPath: String {
        searchDirectories.map(\.path).joined(separator: ":")
    }
}
