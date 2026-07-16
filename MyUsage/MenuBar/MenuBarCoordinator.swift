import AppKit
import Observation

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
    }

    private func observeLayout() {
        withObservationTracking { [weak self] in
            self?.applyLayoutIfChanged()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeLayout()
            }
        }
    }

    private func applyLayoutIfChanged() {
        let layout = currentLayout()
        guard layout != appliedLayout else { return }
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
