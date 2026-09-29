import AppKit
import GSComposerCore
import MetalKit
import SwiftUI

/// MTKView with orbit (drag), pan (right/option-drag, two-finger scroll) and zoom (pinch, ⌘-scroll).
final class InteractiveMTKView: MTKView {
    weak var renderer: SplatRenderer?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDragged(with event: NSEvent) {
        guard let r = renderer else { return }
        if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.shift) {
            r.camera.pan(dx: Float(event.deltaX), dy: Float(event.deltaY), viewHeight: Float(bounds.height))
        } else {
            r.camera.orbit(dx: Float(event.deltaX), dy: Float(event.deltaY))
        }
        r.cameraChanged()
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard let r = renderer else { return }
        r.camera.pan(dx: Float(event.deltaX), dy: Float(event.deltaY), viewHeight: Float(bounds.height))
        r.cameraChanged()
    }

    override func otherMouseDragged(with event: NSEvent) {
        rightMouseDragged(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let r = renderer else { return }
        if event.hasPreciseScrollingDeltas && !event.modifierFlags.contains(.command) {
            r.camera.pan(dx: -Float(event.scrollingDeltaX), dy: -Float(event.scrollingDeltaY), viewHeight: Float(bounds.height))
        } else {
            r.camera.zoom(pow(1.01, -Float(event.scrollingDeltaY)))
        }
        r.cameraChanged()
    }

    override func magnify(with event: NSEvent) {
        guard let r = renderer else { return }
        r.camera.zoom(1 / (1 + Float(event.magnification)))
        r.cameraChanged()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2, let r = renderer {
            r.resetCamera()
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let r = renderer else { return super.keyDown(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "r": r.resetCamera()
        case "f": r.camera.up = -r.camera.up; r.cameraChanged()
        case "=", "+": r.camera.zoom(0.9); r.cameraChanged()
        case "-": r.camera.zoom(1.1); r.cameraChanged()
        default: super.keyDown(with: event)
        }
    }
}

extension SplatRenderer {
    func resetCamera() {
        guard let scene = sceneForCamera else { return }
        let up = camera.up
        camera = OrbitCamera()
        camera.up = up
        camera.frame(center: scene.center, radius: scene.radius)
        cameraChanged()
    }
}

struct SplatViewer: NSViewRepresentable {
    let url: URL?
    var flipUp: Bool
    var onStatus: (String) -> Void = { _ in }

    final class Coordinator {
        var renderer: SplatRenderer?
        var loadedURL: URL?
        var loadedDate: Date?
        var loadTask: Task<Void, Never>?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> InteractiveMTKView {
        let view = InteractiveMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.framebufferOnly = true
        let renderer = SplatRenderer(view: view)
        view.delegate = renderer
        view.renderer = renderer
        context.coordinator.renderer = renderer
        if renderer == nil { onStatus("Metal を初期化できませんでした") }
        return view
    }

    func updateNSView(_ view: InteractiveMTKView, context: Context) {
        let coord = context.coordinator
        guard let renderer = coord.renderer else { return }
        let wantUp = SIMD3<Float>(0, flipUp ? 1 : -1, 0)
        if renderer.camera.up != wantUp {
            renderer.camera.up = wantUp
            renderer.cameraChanged()
        }
        guard let url else { return }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard url != coord.loadedURL || modified != coord.loadedDate else { return }
        let firstLoad = !renderer.hasScene
        coord.loadedURL = url
        coord.loadedDate = modified
        coord.loadTask?.cancel()
        let status = onStatus
        status("読み込み中… \(url.lastPathComponent)")
        coord.loadTask = Task.detached(priority: .userInitiated) {
            do {
                let cloud = try SplatLoader.load(url: url)
                let scene = SplatScene(cloud: cloud)
                if Task.isCancelled { return }
                await MainActor.run {
                    renderer.setScene(scene, resetCamera: firstLoad)
                    status("\(url.lastPathComponent) — \(cloud.count.formatted()) splats")
                }
            } catch {
                await MainActor.run { status("読み込み失敗: \(error.localizedDescription)") }
            }
        }
    }
}
