import AppKit
import SwiftUI

/// Makes the app a regular foreground app even when launched as a bare executable (`swift run`).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate()
        ClickDiagnostics.install()
        DispatchQueue.main.async {
            NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        }
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

/// Debug-only: logs where each mouse-down lands (stderr + ~/Library/Logs/GSComposer-clicks.log).
enum ClickDiagnostics {
    static let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/GSComposer-clicks.log")

    static func install() {
        try? Data().write(to: logURL)
        log("launch pid=\(ProcessInfo.processInfo.processIdentifier) bundle=\(Bundle.main.bundleIdentifier ?? "nil") os=\(ProcessInfo.processInfo.operatingSystemVersionString) policy=\(NSApp.activationPolicy().rawValue)")
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown]) { event in
            describe(event)
            return event
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { n in
                log("\(n.name.rawValue) \((n.object as? NSWindow).map(windowInfo) ?? "")")
            }
        }
    }

    static func windowInfo(_ w: NSWindow) -> String {
        "win#\(w.windowNumber) \(type(of: w)) title='\(w.title)' key=\(w.isKeyWindow) main=\(w.isMainWindow) level=\(w.level.rawValue) alpha=\(w.alphaValue) ignoresMouse=\(w.ignoresMouseEvents) sheet=\(w.attachedSheet != nil) frame=\(NSStringFromRect(w.frame))"
    }

    static func describe(_ event: NSEvent) {
        var line = "\(event.type == .leftMouseDown ? "DOWN" : event.type == .leftMouseUp ? "UP" : "RDOWN") screen=\(NSStringFromPoint(NSEvent.mouseLocation)) active=\(NSApp.isActive) modal=\(NSApp.modalWindow.map(windowInfo) ?? "nil")"
        if let w = event.window {
            line += " \(windowInfo(w)) inWin=\(NSStringFromPoint(event.locationInWindow))"
            if let frameView = w.contentView?.superview, let hit = frameView.hitTest(event.locationInWindow) {
                var chain: [String] = []
                var v: NSView? = hit
                while let cur = v, chain.count < 8 { chain.append("\(type(of: cur))\(NSStringFromRect(cur.frame))"); v = cur.superview }
                line += " hit=" + chain.joined(separator: " < ")
            } else {
                line += " hit=nil"
            }
        } else {
            line += " window=nil"
        }
        let under = NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0)
        line += " topWindowAtPoint=#\(under)"
        log(line)
    }

    static func log(_ s: String) {
        let text = "\(Date().formatted(.iso8601)) \(s)\n"
        FileHandle.standardError.write(Data(text.utf8))
        if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close() }
    }
}
