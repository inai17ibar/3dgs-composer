import Foundation
import GSComposerCore

/// User-selected executable paths (Settings), falling back to PATH / Homebrew discovery.
enum ToolPreferences {
    static func key(_ tool: ExternalTool) -> String { "toolPath.\(tool.rawValue)" }

    static func override(for tool: ExternalTool) -> URL? {
        guard let path = UserDefaults.standard.string(forKey: key(tool)), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    static func setOverride(_ url: URL?, for tool: ExternalTool) {
        UserDefaults.standard.set(url?.path, forKey: key(tool))
    }

    static var locator: ToolLocator {
        var overrides: [ExternalTool: URL] = [:]
        for tool in ExternalTool.allCases {
            if let url = override(for: tool) { overrides[tool] = url }
        }
        return ToolLocator(overrides: overrides)
    }
}
