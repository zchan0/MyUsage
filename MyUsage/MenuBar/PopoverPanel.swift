import AppKit
import SwiftUI

/// Borderless status-bar panel that hosts `UsagePopover` and sizes itself to
/// the SwiftUI content's measured height. Unlike `MenuBarExtra(.window)`,
/// which grows to the tallest content it has shown and won't shrink back
/// (leaving a transparent strip below the footer), this panel is driven
/// directly by the content size reported via `onContentResize`, so it tracks
/// the real height in both directions.
///
/// Style mask `.titled + .nonactivatingPanel + .utilityWindow +
/// .fullSizeContentView` matches FluidMenuBarExtra's known-good recipe and
/// lets the OS provide the rounded popover chrome (corners + shadow). We do
/// NOT add our own corner-masking layer — the layer mask would clip the
/// `NSVisualEffectView` but not the `NSHostingView` subview, leaving the
/// SwiftUI content visible at the corner cutouts.
@MainActor
final class PopoverPanel: NSPanel {
    /// Invoked when the hosted SwiftUI content reports a new size. The owner
    /// (StatusItemController) re-anchors and resizes the window in response.
    var onContentResize: ((CGSize) -> Void)?

    private let visualEffectView: NSVisualEffectView
    private let hostingView: NSHostingView<AnyView>

    init(manager: UsageManager, updateChecker: UpdateChecker) {
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.translatesAutoresizingMaskIntoConstraints = true
        self.visualEffectView = effect

        self.hostingView = NSHostingView(rootView: AnyView(EmptyView()))

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 200),
            styleMask: [.titled, .nonactivatingPanel, .utilityWindow, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isMovable = false
        isMovableByWindowBackground = false
        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        animationBehavior = .none
        collectionBehavior = [.stationary, .moveToActiveSpace, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false

        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        // The hosting view drives its own size; we forward the measured size
        // to `onContentResize` instead of letting SwiftUI resize the window.
        //
        // `.ignoresSafeArea()` is required: with the `.titled` style, even
        // with `.fullSizeContentView`, SwiftUI respects the window's safe
        // area (the invisible titlebar inset) and lays content out below it.
        // When we then size the panel to the ideal content height, SwiftUI
        // gets `idealHeight - titlebar` to draw in and overflows past the
        // bottom — clipping the footer gear. Ignoring safe area gives
        // SwiftUI the whole frame, matching the panel size exactly.
        let content = UsagePopover()
            .environment(manager)
            .environment(updateChecker)
            .ignoresSafeArea()
            .onSizeChange { [weak self] size in
                self?.onContentResize?(size)
            }
        hostingView.rootView = AnyView(content)
        hostingView.sizingOptions = []
        hostingView.isVerticalContentSizeConstraintActive = false
        hostingView.isHorizontalContentSizeConstraintActive = false
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        contentView = effect
        effect.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: effect.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
        ])

        // Force an initial layout pass so the hosting view's
        // intrinsicContentSize reflects the real SwiftUI content size
        // before the panel first appears. Otherwise the panel opens at
        // a too-small size and then animates up to the real one — which
        // on macOS 26 looks like a top-down spring/bounce.
        effect.layoutSubtreeIfNeeded()
        setContentSize(hostingView.intrinsicContentSize)
    }

    override var canBecomeKey: Bool { true }
}
