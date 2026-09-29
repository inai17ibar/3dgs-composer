import AppKit
import SwiftUI

/// Makes the app a regular foreground app even when launched as a bare executable (`swift run`).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct GSComposerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("3DGS Composer") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("動画を開く…") { model.pickInputs(kind: .video) }
                    .keyboardShortcut("o")
                Button("写真を開く…") { model.pickInputs(kind: .photos) }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("3DGS ファイルを表示… (.ply / .splat)") { model.openSplatFile() }
                    .keyboardShortcut("l")
                Button("プロジェクトを開く…") { model.openExistingWorkspace() }
            }
            CommandMenu("作成") {
                Button("3DGS を作成") { model.start() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.canStart)
                Button("学習のみやり直す") { model.retrain() }
                    .disabled(!model.canRetrain)
                Button("キャンセル") { model.cancel() }
                    .keyboardShortcut(".")
                    .disabled(!model.isRunning)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
