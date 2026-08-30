import AppKit
import SwiftUI

/// Turns the host window into a compact glass panel: translucent so the desktop shows
/// through the material, draggable from anywhere, and free of title-bar chrome so the
/// gradient runs edge to edge behind the traffic lights. The title bar itself is hidden
/// via `.windowStyle(.hiddenTitleBar)` on the scene.
struct WindowConfigurator: NSViewRepresentable {

    func makeNSView(context: Context) -> NSView { ConfiguringView() }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ConfiguringView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }

            window.isMovableByWindowBackground = true
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            window.styleMask.insert(.fullSizeContentView)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.collectionBehavior.insert(.fullScreenAuxiliary)
        }
    }
}
