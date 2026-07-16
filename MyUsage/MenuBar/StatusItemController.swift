import AppKit
import SwiftUI
import Observation

/// Owns one menu-bar status item and its popover panel, replacing
/// `MenuBarExtra`. Toggling, anchoring, and dismiss-on-outside-click are all
/// handled here so the panel can be sized deterministically (see `PopoverPanel`).
///
/// `kind == nil` is the merged item (Overview + tabs panel); a non-nil kind
/// is one provider's own item in separate-icons mode, whose panel shows only
/// that provider. `MenuBarCoordinator` decides which set of controllers
/// exists at any moment.
@MainActor
final class StatusItemController: NSObject, NSWindowDelegate {
    private let manager: UsageManager
    private let statusItem: NSStatusItem
    private let panel: PopoverPanel
    /// nil = merged mode item.
    private let kind: ProviderKind?

    private var localMonitor: LocalEventMonitor?
    private var globalMonitor: GlobalEventMonitor?
    private var fallbackIcon: NSImage?
    private var isTornDown = false

    init(manager: UsageManager, updateChecker: UpdateChecker, kind: ProviderKind? = nil) {
        self.manager = manager
        self.kind = kind
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let kind {
            self.panel = PopoverPanel(
                manager: manager,
                updateChecker: updateChecker,
                rootView: AnyView(ProviderPopover(kind: kind))
            )
        } else {
            self.panel = PopoverPanel(manager: manager, updateChecker: updateChecker)
        }
        super.init()

        configureButton()
        startObservingManager()

        panel.delegate = self
        panel.onContentResize = { [weak self] size in
            self?.setPanelFrame(size: size)
        }

        // Intercept clicks on the status item ourselves and consume them so
        // the button never receives the down-event. Using button.target/action
        // races with `windowDidResignKey` (clicking an open status item could
        // hide-then-reopen mid-event); consuming the event sidesteps that.
        localMonitor = LocalEventMonitor(mask: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self,
                      let button = self.statusItem.button,
                      event.window == button.window else { return false }
                self.togglePanel()
                return true
            }
            return handled ? nil : event
        }
        localMonitor?.start()

        globalMonitor = GlobalEventMonitor(mask: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel.isKeyWindow else { return }
                self.panel.resignKey()
            }
        }
    }

    // MARK: Status-bar button

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageLeft
        button.imageScaling = .scaleNone
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        button.imageHugsTitle = true
        fallbackIcon = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "MyUsage")
        fallbackIcon?.isTemplate = true
    }

    /// Re-renders the status-item icon + title whenever the observed
    /// `@Observable` manager properties change. Re-arms tracking each pass.
    private func startObservingManager() {
        guard !isTornDown else { return }
        withObservationTracking { [weak self] in
            self?.updateButton()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.startObservingManager()
            }
        }
    }

    private func updateButton() {
        guard !isTornDown, let button = statusItem.button else { return }
        if let kind {
            // Separate mode: this item IS one provider — fixed icon, that
            // provider's own label text.
            button.image = ProviderTemplateIcon.image(for: kind) ?? fallbackIcon
            button.title = manager.menuBarText(for: kind) ?? ""
        } else {
            let providerImage = ProviderKind(rawValue: manager.iconTrackProvider)
                .flatMap { ProviderTemplateIcon.image(for: $0) }
            button.image = providerImage ?? fallbackIcon
            button.title = manager.menuBarDisplayText ?? ""
        }
    }

    // MARK: Teardown

    /// Remove this item from the menu bar and stop all event monitors.
    /// Called by `MenuBarCoordinator` when the mode or the enabled-provider
    /// set changes and this controller is no longer part of the layout.
    func tearDown() {
        isTornDown = true
        hidePanel()
        localMonitor?.stop()
        localMonitor = nil
        globalMonitor?.stop()
        globalMonitor = nil
        panel.close()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    // MARK: Panel toggle

    private func togglePanel() {
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        // Flush any pending content-size change WHILE STILL HIDDEN so the
        // panel is correctly sized before it appears. The content can change
        // height between shows (a refresh updated a card), and because the
        // resize-while-hidden path snaps without animation, doing it here
        // means the post-show measurement matches the panel and won't trigger
        // a visible catch-up animation.
        panel.contentView?.layoutSubtreeIfNeeded()
        setPanelFrame(size: panel.frame.size)

        // Tell the system menu UI that menu tracking has begun, otherwise it
        // may dismiss our panel as a "menu that never appeared" — which
        // manifests as needing several clicks to keep the popover open.
        DistributedNotificationCenter.default().post(name: .beginMenuTracking, object: nil)
        panel.makeKeyAndOrderFront(nil)
        globalMonitor?.start()
        Task { await manager.refreshAll() }
    }

    private func hidePanel() {
        DistributedNotificationCenter.default().post(name: .endMenuTracking, object: nil)
        globalMonitor?.stop()
        panel.orderOut(nil)
    }

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        hidePanel()
    }

    // MARK: Anchoring

    /// Place the panel directly below the status-item button, centered on it,
    /// keeping the top edge pinned so resizes grow/shrink downward. Clamp the
    /// horizontal position to the visible screen so it never spills off-edge.
    ///
    /// Animation is gated on `panel.isVisible`: a *visible* content resize
    /// (provider added/removed, refresh changed a card) animates smoothly
    /// downward; a resize while hidden — including the one that positions the
    /// panel just before it's shown — snaps instantly. Without this gate the
    /// panel animates its frame on first appearance, so instead of dropping
    /// from the menu-bar button it slides in from wherever its previous frame
    /// happened to be. The animated path is also deferred a runloop tick so
    /// it starts only after SwiftUI commits the new layout.
    private func setPanelFrame(size: CGSize) {
        guard let buttonWindow = statusItem.button?.window else { return }
        let buttonFrame = buttonWindow.frame

        var frame = CGRect(origin: buttonFrame.origin, size: size)
        frame.origin.y = buttonFrame.origin.y - size.height
        frame.origin.x = buttonFrame.origin.x + (buttonFrame.width / 2) - (size.width / 2)

        if let screen = buttonWindow.screen {
            let visible = screen.visibleFrame
            let inset: CGFloat = 8
            if frame.maxX > visible.maxX {
                frame.origin.x = visible.maxX - size.width - inset
            }
            if frame.minX < visible.minX {
                frame.origin.x = visible.minX + inset
            }
        }

        guard frame != panel.frame else { return }

        // Always defer to the next runloop tick — applying setFrame
        // synchronously during SwiftUI's layout pass races it and the height
        // ends up wrong. Only the ANIMATION is gated on visibility: a resize
        // while the panel is shown animates; one while hidden (including the
        // pre-show positioning) snaps, so the panel never slides in from a
        // stale frame on first appearance. `animate` is captured now, before
        // the panel is ordered front, so the show path stays un-animated.
        let animate = panel.isVisible
        DispatchQueue.main.async { [weak self] in
            self?.panel.setFrame(frame, display: true, animate: animate)
        }
    }
}

private extension Notification.Name {
    /// Posted to the system menu UI when a menu starts/ends tracking. We use
    /// these so AppKit treats our popover panel like a real menu (doesn't
    /// auto-dismiss it, keeps the menu bar persistent in full-screen mode).
    static let beginMenuTracking = Notification.Name("com.apple.HIToolbox.beginMenuTrackingNotification")
    static let endMenuTracking = Notification.Name("com.apple.HIToolbox.endMenuTrackingNotification")
}
