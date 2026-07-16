import AppKit
import Observation
import os

/// Decides which status items exist, based on `UsageManager.menuBarMode`
/// and the enabled-provider set (the CodexBar model):
///
/// - `merged`: one item; its panel is the Overview + provider tabs.
/// - `separate`: one item per enabled provider, in display order; each
///   panel shows only that provider. No Overview, no tab strip.
///
/// Rebuilds tear down the old controllers (removing their status items)
/// before creating the new set, so toggling the mode or a provider in
/// Settings updates the menu bar immediately.
@MainActor
final class MenuBarCoordinator {
    private let manager: UsageManager
    private let updateChecker: UpdateChecker
    private var controllers: [StatusItemController] = []
    /// Fingerprint of the last-applied layout, so observation ticks that
    /// change unrelated manager state don't rebuild (and flicker) the bar.
    private var appliedLayout: [String] = []

    init(manager: UsageManager, updateChecker: UpdateChecker) {
        self.manager = manager
        self.updateChecker = updateChecker
        observeLayout()

        #if DEBUG
        // Automation hook: bumping `debugTogglePanel` (int) via
        // `defaults write MyUsage debugTogglePanel -int N` toggles the
        // panel of the status item at `debugToggleIndex`.
        debugToggleObserver = DefaultsKeyObserver(key: "debugTogglePanel") { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let counter = UserDefaults.standard.integer(forKey: "debugTogglePanel")
                guard counter != self.lastDebugToggle else { return }
                self.lastDebugToggle = counter
                let index = UserDefaults.standard.integer(forKey: "debugToggleIndex")
                guard self.controllers.indices.contains(index) else { return }
                self.controllers[index].debugToggle()
            }
        }
        #endif
    }

    #if DEBUG
    private var lastDebugToggle = 0
    private var debugToggleObserver: DefaultsKeyObserver?

    /// Autopilot access — toggle the panel of status item `index`.
    func debugToggle(_ index: Int) {
        guard controllers.indices.contains(index) else {
            DebugLog.info("debugToggle(\(index)): no such controller (count=\(controllers.count))")
            return
        }
        controllers[index].debugToggle()
    }

    func debugSnapshot(_ index: Int, to path: String) {
        guard controllers.indices.contains(index) else { return }
        controllers[index].debugSnapshot(to: path)
    }
    #endif

    private func observeLayout() {
        // Track ONLY the layout inputs (mode + enabled set). Building the
        // controllers happens outside the tracked scope — their own
        // updateButton() observation must not register snapshot/refresh
        // state as dependencies of the coordinator, or every refresh tick
        // re-enters here.
        let layout = withObservationTracking { [weak self] in
            self?.currentLayout() ?? []
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeLayout()
            }
        }
        applyIfChanged(layout)
    }

    private func applyIfChanged(_ layout: [String]) {
        guard layout != appliedLayout else { return }
        Logger.general.info("MenuBar layout rebuild: \(self.appliedLayout.joined(separator: ","), privacy: .public) -> \(layout.joined(separator: ","), privacy: .public)")
        DebugLog.info("MenuBar rebuild: \(appliedLayout) -> \(layout)")
        appliedLayout = layout

        for controller in controllers {
            controller.tearDown()
        }
        controllers = layout.map { slot in
            StatusItemController(
                manager: manager,
                updateChecker: updateChecker,
                kind: ProviderKind(rawValue: slot)
            )
        }
    }

    /// One string per status item. "merged" is not a ProviderKind raw
    /// value, so it maps to `kind: nil` in the controller. Separate mode
    /// lists providers reversed: NSStatusBar inserts each new item to the
    /// LEFT of the previous one, so reversing yields display order.
    private func currentLayout() -> [String] {
        switch manager.menuBarMode {
        case .merged:
            return ["merged"]
        case .separate:
            let enabled = manager.orderedProviders.filter(\.isEnabled).map(\.kind.rawValue)
            // Fall back to the merged item rather than zero icons — an
            // app with no menu-bar presence is unrecoverable without
            // relaunching into Settings.
            return enabled.isEmpty ? ["merged"] : enabled.reversed()
        }
    }
}
