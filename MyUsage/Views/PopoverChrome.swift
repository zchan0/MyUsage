import SwiftUI
import AppKit

/// Rounded material backing for the menu-bar popover.
///
/// `MenuBarExtra(.window)` hosts the popover in a system panel that draws
/// its own rounded corners + material. After the macOS 26 update, when the
/// SwiftUI content resizes (taller via `fixedSize`, or when switching
/// accounts), the panel's corner-rounding mask doesn't keep up — the new
/// corners stop being masked. We take over the chrome: make the panel
/// transparent (`PopoverWindowConfigurator`) and draw our own rounded
/// `NSVisualEffectView` that tracks the content's real size.
///
/// The subtlety: a layer's `bounds` change animates implicitly via
/// CoreAnimation (~0.25s). During that animation the rounded mask is still
/// at the OLD (smaller) size, so the bottom corners briefly expose the
/// now-transparent window — the "corner goes transparent after switching
/// accounts" bug. `RoundedMaterialView` kills the implicit animations so
/// the mask snaps to the new bounds in the same frame as the resize.
struct PopoverMaterialBackground: NSViewRepresentable {
    var cornerRadius: CGFloat = 12

    func makeNSView(context: Context) -> RoundedMaterialView {
        let view = RoundedMaterialView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        view.cornerRadius = cornerRadius
        return view
    }

    func updateNSView(_ view: RoundedMaterialView, context: Context) {
        view.cornerRadius = cornerRadius
    }
}

/// `NSVisualEffectView` that rounds its own corners with no implicit layer
/// animation, so the mask tracks live resizes exactly instead of lagging.
final class RoundedMaterialView: NSVisualEffectView {
    var cornerRadius: CGFloat = 12 {
        didSet { applyMask() }
    }

    override func makeBackingLayer() -> CALayer {
        let layer = super.makeBackingLayer()
        // Never implicitly animate geometry/mask changes — they must
        // resolve in the same frame as the window resize, otherwise the
        // rounded mask lags and exposes the clear window at the corners.
        layer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "cornerRadius": NSNull(),
        ]
        return layer
    }

    override func layout() {
        super.layout()
        applyMask()
    }

    private func applyMask() {
        wantsLayer = true
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.cornerRadius = cornerRadius
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        CATransaction.commit()
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
