import GSComposerCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var showGuide = false

    var body: some View {
        @Bindable var model = model
        // NavigationSplitView のサイドバー列に ScrollView を置くと、中のボタンにクリックが届かない
        // (hitTest が PlatformGroupContainer で止まる)。List なら正しくルーティングされる。
        List {
            VStack(alignment: .leading, spacing: 16) {
                inputSection
                Divider()
                settingsSection
                Divider()
                runSection
                StageListView()
            }
            .padding(.vertical, 8)
        }
        .listStyle(.sidebar)
        .sheet(isPresented: $showGuide) { ShootingGuideView() }
    }

    private var inputSection: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("入力").font(.headline)
                Spacer()
                Button { showGuide = true } label: {
                    Label("撮影ガイド", systemImage: "questionmark.circle")
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            HStack {
                Button { model.pickInputs(kind: .video) } label: {
                    Label("動画を選択", systemImage: "film")
                        .frame(maxWidth: .infinity)
                }
                Button { model.pickInputs(kind: .photos) } label: {
                    Label("写真を選択", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(model.isRunning)
            HStack {
                Image(systemName: model.inputKind == .video ? "film" : "photo.stack")
                Text(model.inputSummary).lineLimit(1).truncationMode(.middle)
            }
            .foregroundStyle(model.inputURLs.isEmpty ? .secondary : .primary)
            if let summary = model.arkitSummary {
                Toggle(isOn: $model.useARKitPoses) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("iPhone で記録したカメラ姿勢を使う（推奨）")
                        Text(summary).font(.caption).foregroundStyle(.secondary)
                        Text("COLMAP の姿勢推定（SfM）を省略し、ARKit の姿勢で 3D 点を作ります。SfM が失敗する撮影でも復元できます。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(model.isRunning)
            }
            Text("ファイルやフォルダをウィンドウにドロップしても追加できます。被写体の周りを同じ距離で、高さを変えて何周か撮ると良い結果になります（撮影ガイド参照）。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var settingsSection: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 8) {
            Text("設定").font(.headline)
            Picker("品質", selection: $model.preset) {
                ForEach(QualityPreset.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Picker("学習エンジン", selection: $model.settings.trainer) {
                ForEach(TrainerKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            if model.inputKind == .video {
                Stepper("抽出フレーム数: \(model.settings.targetFrameCount)", value: $model.settings.targetFrameCount, in: 20...1000, step: 10)
                if let n = model.recommendedFrameCount, n != model.settings.targetFrameCount {
                    Button("撮影の長さに合わせたおすすめ: \(n) 枚") { model.settings.targetFrameCount = n }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                Toggle("ブレの少ないフレームを優先", isOn: $model.settings.pickSharpestFrames)
            }
            DisclosureGroup("詳細設定") {
                AdvancedSettingsView()
                    .padding(.top, 4)
            }
        }
        .disabled(model.isRunning)
    }

    private var runSection: some View {
        HStack {
            if model.isRunning {
                Button(role: .cancel) { model.cancel() } label: {
                    Label("キャンセル", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                if let started = model.startedAt {
                    Text(started, style: .timer)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            } else {
                Button { model.start() } label: {
                    Label("3DGS を作成", systemImage: "sparkles").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.canStart)
                if model.canRetrain {
                    Button("再学習") { model.retrain() }
                        .controlSize(.large)
                        .help("カメラ姿勢推定の結果を再利用し、3DGS 学習だけをやり直します")
                }
            }
        }
    }
}

struct AdvancedSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("COLMAP") {
                Picker("カメラモデル", selection: $model.settings.cameraModel) {
                    ForEach(ColmapCameraModel.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Toggle("全画像で同じカメラ", isOn: $model.settings.singleCamera)
                Picker("マッチング", selection: $model.settings.matcher) {
                    ForEach(MatcherKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("SfM", selection: $model.settings.mapper) {
                    ForEach(MapperKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Stepper("最大画像サイズ: \(model.settings.maxImageSize)px", value: $model.settings.maxImageSize, in: 640...4000, step: 160)
                Stepper("特徴点数: \(model.settings.maxFeatures)", value: $model.settings.maxFeatures, in: 1024...32768, step: 1024)
            }
            Section("3DGS 学習") {
                Stepper("ステップ数: \(model.settings.totalSteps.formatted())", value: $model.settings.totalSteps, in: 1000...100_000, step: 1000)
                Stepper("球面調和 次数: \(model.settings.shDegree)", value: $model.settings.shDegree, in: 0...3)
                Stepper("最大 splat 数: \(model.settings.maxSplats.formatted())", value: $model.settings.maxSplats, in: 100_000...10_000_000, step: 100_000)
                Stepper("途中経過の保存間隔: \(model.settings.exportEvery)", value: $model.settings.exportEvery, in: 100...10_000, step: 100)
                TextField("追加引数", text: $model.settings.extraTrainerArguments, prompt: Text("例: --ssim-weight 0.2"))
                    .font(.system(.body, design: .monospaced))
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

struct StageListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.stages) { state in
                HStack(alignment: .top, spacing: 8) {
                    icon(for: state.status)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(state.stage.title)
                            .foregroundStyle(state.status == .pending ? .secondary : .primary)
                        if state.status == .running {
                            if let f = state.fraction {
                                ProgressView(value: f)
                            } else {
                                ProgressView().progressViewStyle(.linear)
                            }
                        }
                        if let detail = state.detail {
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func icon(for status: StageStatus) -> some View {
        switch status {
        case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }
}
