import SwiftUI
import AppKit

/// Rounded material backing for the menu-bar popover.
///
/// `MenuBarExtra(.window)` hosts the popover in a system panel that draws
/// its own rounded corners + material. After the macOS 26 update, when the
/// SwiftUI content resizes taller (via `fixedSize`), the panel's
/// corner-rounding mask doesn't keep up — the new top/bottom corners stop
/// being masked and the panel's opaque backing shows through (a white
/// notch in dark mode). We take over the chrome: make the panel itself
/// transparent (`PopoverWindowConfigurator`) and draw our own rounded
/// `NSVisualEffectView` that always tracks the content's real size, so the
/// corners are correct at any height.
struct PopoverMaterialBackground: NSViewRepresentable {
    var cornerRadius: CGFloat = 12

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.layer?.cornerRadius = cornerRadius
    }
}

/// Walks up to the hosting `NSWindow` and clears its background so only our
/// rounded material shows — no square opaque backing peeking out at the
/// corners. Keeps the window shadow (it follows the opaque rounded content).
struct PopoverWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = true
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
