import AppKit
import SwiftUI

/// Borderless macOS 26 Liquid Glass status-bar panel that hosts `UsagePopover`
/// and sizes itself deterministically to the SwiftUI content's measured height.
///
/// Uses `NSGlassEffectView` as the window's content view with concentric
/// continuous corners (`PopoverLayout.outerCornerRadius`), setting the
/// `NSHostingView` as `glassView.contentView` per AppKit's z-order contract.
@MainActor
final class PopoverPanel: NSPanel {
    let presentation = PopoverPresentation()

    /// Invoked when the hosted SwiftUI content reports a new size. The owner
    /// (`StatusItemController`) re-anchors and resizes the window in response.
    var onContentResize: ((CGSize) -> Void)?

    /// Last ideal size SwiftUI reported via `onSizeChange`.
    private(set) var lastReportedContentSize: CGSize?

    private let glassView: NSGlassEffectView
    private let hostingView: NSHostingView<AnyView>

    /// Merged-mode convenience: hosts the provider dock and selected deck.
    convenience init(manager: UsageManager, updateChecker: UpdateChecker) {
        self.init(manager: manager, updateChecker: updateChecker, rootView: AnyView(UsagePopover(manager: manager)))
    }

    /// Host an arbitrary SwiftUI root (separate mode passes a single provider's popover).
    init(manager: UsageManager, updateChecker: UpdateChecker, rootView: AnyView) {
        let glass = NSGlassEffectView()
        glass.style = .regular
        glass.cornerRadius = PopoverLayout.outerCornerRadius
        glass.translatesAutoresizingMaskIntoConstraints = true
        glass.autoresizingMask = [.width, .height]
        self.glassView = glass

        self.hostingView = NSHostingView(rootView: AnyView(EmptyView()))

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: PopoverLayout.width, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isMovable = false
        isMovableByWindowBackground = false
        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        collectionBehavior = [.stationary, .moveToActiveSpace, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        contentMinSize = NSSize(width: PopoverLayout.width, height: 80)

        let content = rootView
            .environment(\.popoverPresentation, presentation)
            .environment(manager)
            .environment(updateChecker)
            .onSizeChange { [weak self] size in
                self?.lastReportedContentSize = size
                self?.onContentResize?(size)
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
            .clipShape(RoundedRectangle(cornerRadius: PopoverLayout.outerCornerRadius, style: .continuous))
        hostingView.rootView = AnyView(content)
        hostingView.safeAreaRegions = []
        hostingView.sizingOptions = []
        hostingView.isVerticalContentSizeConstraintActive = false
        hostingView.isHorizontalContentSizeConstraintActive = false
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = [.width, .height]

        glass.contentView = hostingView
        contentView = glass

        // Force an initial layout pass so intrinsicContentSize reflects real SwiftUI content
        // before the panel first appears.
        glass.layoutSubtreeIfNeeded()
        setContentSize(Self.sanitized(hostingView.intrinsicContentSize))
    }

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
        if out.height < 80 { out.height = 200 }
        return out
    }

    override var canBecomeKey: Bool { true }
}
