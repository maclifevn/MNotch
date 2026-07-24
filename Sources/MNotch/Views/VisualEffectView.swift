import AppKit
import SwiftUI

/// NSVisualEffectView bridge used only inside lock-screen cards. Expanded
/// notch panels stay opaque black to avoid wallpaper-dependent white halos.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.state = .active
        view.blendingMode = .behindWindow
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
