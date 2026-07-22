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

    /// Last ideal size SwiftUI reported via onSizeChange. This is the ONE
    /// trustworthy measurement: AppKit-side `intrinsicContentSize` /
    /// `fittingSize` on the hosting view can return invalid values at
    /// arbitrary times (they produced the 0×0 and 200pt-placeholder
    /// panels). SwiftUI reports it even while the panel is hidden.
    private(set) var lastReportedContentSize: CGSize?

    private let visualEffectView: NSVisualEffectView
    private let hostingView: NSHostingView<AnyView>

    /// Merged-mode convenience: hosts the Overview + tabs popover.
    convenience init(manager: UsageManager, updateChecker: UpdateChecker) {
        self.init(manager: manager, updateChecker: updateChecker, rootView: AnyView(UsagePopover()))
    }

    /// Host an arbitrary SwiftUI root (separate mode passes a single
    /// provider's popover). Environment objects and the size-tracking
    /// wrapper are applied here either way.
    init(manager: UsageManager, updateChecker: UpdateChecker, rootView: AnyView) {
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.translatesAutoresizingMaskIntoConstraints = true
        // As the window's contentView, the effect must fill the whole window
        // on every resize. Without an explicit autoresizing mask it can lag
        // behind a `setFrame`, ending up shorter than the window — and since
        // the hosting view is its subview, the window clips the hosting view's
        // overflow (footer cut off). Pinning width+height keeps the effect,
        // and therefore the clip bounds, exactly the window size.
        effect.autoresizingMask = [.width, .height]
        self.visualEffectView = effect

        self.hostingView = NSHostingView(rootView: AnyView(EmptyView()))

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: PopoverLayout.width, height: 200),
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
        // Floor the content size so a transient zero/tiny height measurement
        // (e.g. during the first layout pass) can't collapse the panel.
        contentMinSize = NSSize(width: PopoverLayout.width, height: 80)

        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        // The hosting view drives its own size; we forward the measured size
        // to `onContentResize` instead of letting SwiftUI resize the window.
        //
        // Layout recipe adapted from FluidMenuBarExtra (`RootViewModifier`):
        //   1. measure the content's IDEAL size (GeometryReader, via
        //      `onSizeChange`) — this drives the window resize;
        //   2. wrap that in `.frame(maxHeight: .infinity, alignment: .top)`
        //      so the SwiftUI view ALWAYS fills the hosting view (which is
        //      pinned to the window), with the real content top-aligned.
        //
        // Step 2 is the piece that makes every prior attempt's symptoms go
        // away at once: because the content fills the window, it can never be
        // clipped (no header/footer cut-off) and never leaves a transparent
        // gap on shrink (the empty space below the content shows the window's
        // material, not the cleared window). And because the *measured* size
        // is the inner ideal (taken before the flexible frame), the window
        // tracks the true content height without a feedback loop.
        let content = rootView
            .environment(manager)
            .environment(updateChecker)
            .onSizeChange { [weak self] size in
                self?.lastReportedContentSize = size
                self?.onContentResize?(size)
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        hostingView.rootView = AnyView(content)
        hostingView.safeAreaRegions = []
        hostingView.sizingOptions = []
        hostingView.isVerticalContentSizeConstraintActive = false
        hostingView.isHorizontalContentSizeConstraintActive = false
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        contentView = effect
        effect.addSubview(hostingView)
        // Pin all four edges: the flexible frame above makes the SwiftUI view
        // fill whatever size the window is, so a full-edge pin no longer
        // fights the content's intrinsic height.
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
        setContentSize(Self.sanitized(hostingView.intrinsicContentSize))
    }

    /// Best current measurement of the SwiftUI content, safe against the
    /// hosting view reporting `NSViewNoIntrinsicMetric` (-1) or zero.
    /// Panels created during a menu-bar layout rebuild hit exactly that:
    /// `setContentSize(-1, -1)` collapsed the window to 0×0, SwiftUI never
    /// lays out inside a zero window, so the self-correcting resize
    /// callback never fired — the panel "showed" as an invisible zero-size
    /// key window (clicks looked dead, and it invisibly stole focus).
    func measuredContentSize() -> CGSize {
        if let reported = lastReportedContentSize, reported.height > 80 {
            return reported
        }
        contentView?.layoutSubtreeIfNeeded()
        var size = hostingView.intrinsicContentSize
        if size.width <= 0 || size.height <= 0 {
            size = hostingView.fittingSize
        }
        return Self.sanitized(size)
    }

    private static func sanitized(_ size: CGSize) -> CGSize {
        var out = size
        if out.width <= 0 { out.width = PopoverLayout.width }
        // A real popover is never this short; a placeholder height gets
        // corrected by the first onContentResize once SwiftUI lays out
        // inside a non-zero window.
        if out.height < 80 { out.height = 200 }
        return out
    }

    override var canBecomeKey: Bool { true }
}
