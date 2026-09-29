import GSComposerCore
import SwiftUI

struct SettingsView: View {
    @State private var refresh = 0

    var body: some View {
        Form {
            Section {
                ForEach(ExternalTool.allCases, id: \.self) { tool in
                    ToolRow(tool: tool, refresh: $refresh)
                }
            } header: {
                Text("外部ツール")
            } footer: {
                Text("未指定の場合は PATH と Homebrew (/opt/homebrew/bin) から自動検出します。COLMAP と学習エンジン (Brush か OpenSplat) が必要です。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("入手先") {
                Link("Brush リリース (brush_app)", destination: URL(string: "https://github.com/ArthurBrussee/brush/releases")!)
                Link("COLMAP (brew install colmap)", destination: URL(string: "https://colmap.github.io/install.html")!)
                Link("OpenSplat", destination: URL(string: "https://github.com/pierotofy/OpenSplat")!)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 460)
        .id(refresh)
    }
}

private struct ToolRow: View {
    let tool: ExternalTool
    @Binding var refresh: Int

    var body: some View {
        let located = ToolPreferences.locator.locate(tool)
        let custom = ToolPreferences.override(for: tool)
        HStack {
            Image(systemName: located != nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(located != nil ? .green : .orange)
            VStack(alignment: .leading) {
                Text(tool.rawValue).bold()
                Text(located?.path ?? "見つかりません — \(tool.installHint)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if custom != nil {
                Button("自動") {
                    ToolPreferences.setOverride(nil, for: tool)
                    refresh += 1
                }
            }
            Button("選択…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.message = "\(tool.rawValue) の実行ファイルを選択"
                if panel.runModal() == .OK, let url = panel.url {
                    ToolPreferences.setOverride(url, for: tool)
                    refresh += 1
                }
            }
        }
    }
}
