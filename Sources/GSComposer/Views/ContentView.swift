import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var isDropTargeted = false
    @State private var showLog = true

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 420)
        } detail: {
            VSplitView {
                ViewerPane()
                    .frame(minHeight: 280)
                if showLog {
                    LogView()
                        .frame(minHeight: 120, idealHeight: 200)
                }
            }
            .toolbar {
                ToolbarItemGroup {
                    Button { ClickDiagnostics.log("ACTION toggleLog"); showLog.toggle() } label: {
                        Label("ログ", systemImage: "text.alignleft")
                    }
                    .help("ログの表示/非表示")
                    Menu {
                        Button("PLY (.ply) — 学習結果そのまま") { model.export(as: "ply") }
                        Button("Splat (.splat) — Web ビューア向け") { model.export(as: "splat") }
                    } label: {
                        Label("書き出し", systemImage: "square.and.arrow.up")
                    }
                    .disabled(model.resultURL == nil && model.viewerURL == nil)
                    Button { model.revealWorkspace() } label: {
                        Label("Finder で表示", systemImage: "folder")
                    }
                    .disabled(model.workspace == nil)
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            loadDropped(providers)
            return true
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .background(Color.accentColor.opacity(0.08))
                    .overlay(Text("動画・写真・フォルダ・.ply をドロップ").font(.title2))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .alert("エラー", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private func loadDropped(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        let collector = URLCollector()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { collector.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let urls = collector.urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            if let splat = urls.first(where: { ["ply", "splat"].contains($0.pathExtension.lowercased()) }) {
                model.viewerURL = splat
                model.viewerStep = nil
            } else if !model.isRunning {
                model.setInputs(urls)
            }
        }
    }
}

final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []
    func append(_ url: URL) { lock.lock(); storage.append(url); lock.unlock() }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return storage }
}

struct ViewerPane: View {
    @Environment(AppModel.self) private var model
    @State private var status = ""
    @AppStorage("viewer.flipUp") private var flipUp = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            SplatViewer(url: model.viewerURL, flipUp: flipUp) { status = $0 }
            if model.viewerURL == nil {
                ContentUnavailableView {
                    Label("3DGS プレビュー", systemImage: "cube.transparent")
                } description: {
                    Text("左のパネルで動画または写真を選んで「3DGS を作成」を押してください。\n学習中は途中経過がここに表示されます。")
                }
                .allowsHitTesting(false)
            }
            HStack(spacing: 12) {
                if !status.isEmpty { Text(status) }
                if let step = model.viewerStep { Text("学習ステップ \(step.formatted())") }
                Spacer()
                Toggle("上下反転", isOn: $flipUp).toggleStyle(.checkbox)
                Text("ドラッグ: 回転 / ⌥ドラッグ・右ドラッグ: 移動 / スクロール・ピンチ: ズーム / ダブルクリック: リセット")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(8)
            .background(.ultraThinMaterial)
        }
    }
}
