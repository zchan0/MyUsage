import AppKit
import os
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
        panel.delegate = nil
        panel.close()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    // MARK: Panel toggle

    private var label: String { kind?.rawValue ?? "merged" }

    #if DEBUG
    /// Test hook — drives the same path as a status-item click, and logs
    /// the button's screen frame so automation can post real CGEvent
    /// clicks at it (AX can't reach a bare SPM binary's status items).
    func debugToggle() {
        if let window = statusItem.button?.window {
            DebugLog.info("StatusItem[\(label)] buttonFrame=\(window.frame)")
        }
        togglePanel()
    }

    /// Render the panel's content into a PNG — in-process, permission-free,
    /// pixel-accurate capture for design iteration.
    func debugSnapshot(to path: String) {
        guard let view = panel.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            DebugLog.info("StatusItem[\(label)] snapshot FAILED (no view/rep)")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        DebugLog.info("StatusItem[\(label)] snapshot -> \(path) (\(view.bounds.size))")
    }
    #endif

    private func togglePanel() {
        Logger.general.info("StatusItem[\(self.label, privacy: .public)] click; panelVisible=\(self.panel.isVisible, privacy: .public)")
        DebugLog.info("StatusItem[\(label)] click; visible=\(panel.isVisible)")
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
        // a visible catch-up animation. Uses a fresh measurement rather than
        // the panel's current frame — a panel built during a layout rebuild
        // can be carrying a collapsed frame (see measuredContentSize()).
        // Applied immediately: this is the click path, not a SwiftUI layout
        // pass, so the one-tick deferral would only let the panel flash at
        // its stale frame before makeKeyAndOrderFront.
        setPanelFrame(size: panel.measuredContentSize(), immediate: true)

        // Tell the system menu UI that menu tracking has begun, otherwise it
        // may dismiss our panel as a "menu that never appeared" — which
        // manifests as needing several clicks to keep the popover open.
        DistributedNotificationCenter.default().post(name: .beginMenuTracking, object: nil)
        panel.makeKeyAndOrderFront(nil)
        globalMonitor?.start()
        Logger.general.info("StatusItem[\(self.label, privacy: .public)] showPanel; frame=\(String(describing: self.panel.frame), privacy: .public) visible=\(self.panel.isVisible, privacy: .public)")
        DebugLog.info("StatusItem[\(label)] showPanel frame=\(panel.frame) visible=\(panel.isVisible)")
        Task { await manager.refreshAll() }
    }

    private func hidePanel() {
        // Only balance the tracking notification when the panel is actually
        // up. tearDown() calls this unconditionally on every layout rebuild;
        // posting endMenuTracking without a matching begin desynchronizes
        // HIToolbox's menu-tracking state — after which freshly shown panels
        // get dismissed as "menus that never appeared" (clicks appear dead)
        // and normal windows fight to stay key.
        guard panel.isVisible else { return }
        DistributedNotificationCenter.default().post(name: .endMenuTracking, object: nil)
        globalMonitor?.stop()
        panel.orderOut(nil)
    }

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        Logger.general.info("StatusItem[\(self.label, privacy: .public)] panel resigned key")
        DebugLog.info("StatusItem[\(label)] resignKey")
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
    private func setPanelFrame(size: CGSize, immediate: Bool = false) {
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

        // `immediate` (the click/show path) applies synchronously — that
        // caller is never inside a SwiftUI layout pass, and deferring would
        // let the panel appear at its stale frame for one tick. All other
        // callers (onContentResize) defer to the next runloop tick, because
        // applying setFrame synchronously during SwiftUI's layout pass races
        // it and the height ends up wrong. Only the ANIMATION is gated on
        // visibility: a resize while the panel is shown animates; one while
        // hidden snaps, so the panel never slides in from a stale frame on
        // first appearance.
        DebugLog.info("StatusItem[\(label)] setPanelFrame size=\(size) immediate=\(immediate)")
        if immediate {
            panel.setFrame(frame, display: true, animate: false)
            return
        }
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
