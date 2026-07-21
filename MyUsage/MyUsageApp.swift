import SwiftUI
import AppKit

@main
struct MyUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environment(appDelegate.usageManager)
                .environment(appDelegate.updateChecker)
        }
    }
}

/// Owns the app-wide state and the menu-bar status item. We manage the status
/// item ourselves (see `StatusItemController`) rather than using
/// `MenuBarExtra`, so the popover panel can be sized to its content exactly.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let usageManager: UsageManager
    let updateChecker = UpdateChecker.shared

    private var menuBarCoordinator: MenuBarCoordinator?

    override init() {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["MYUSAGE_PREVIEW_PROVIDERS"],
           let count = Int(raw),
           (1...4).contains(count) {
            usageManager = PreviewFixtures.manager(providerCount: count)
        } else {
            usageManager = UsageManager()
        }
        #else
        usageManager = UsageManager()
        #endif
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarCoordinator = MenuBarCoordinator(manager: usageManager, updateChecker: updateChecker)
        usageManager.startTimer()

        Task { await usageManager.refreshAll() }

        #if DEBUG
        // In-process reproduction harness: MYUSAGE_AUTOPILOT=1 drives the
        // exact code paths the Settings picker and status-item clicks use,
        // with NSLog breadcrumbs, so mode-switch bugs can be reproduced
        // headlessly (`swift run` + grep) instead of by hand.
        // "open:N" opens status item N's panel, waits for data to land,
        // and (when MYUSAGE_SNAPSHOT is set) renders the panel to a PNG —
        // the design-iteration loop.
        if let value = ProcessInfo.processInfo.environment["MYUSAGE_AUTOPILOT"],
           value.hasPrefix("open:"),
           let index = Int(value.dropFirst(5)),
           let coordinator = menuBarCoordinator {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                coordinator.debugToggle(index)
                if let path = ProcessInfo.processInfo.environment["MYUSAGE_SNAPSHOT"] {
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    coordinator.debugSnapshot(index, to: path)
                }
                DebugLog.info("AUTOPILOT open:\(index) done")
            }
        }

        if ProcessInfo.processInfo.environment["MYUSAGE_AUTOPILOT"] == "1",
           let coordinator = menuBarCoordinator {
            Task { @MainActor [usageManager] in
                @MainActor func step(_ name: String, _ body: @MainActor () -> Void) async {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    DebugLog.info("AUTOPILOT step: \(name)")
                    body()
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await step("open merged panel") { coordinator.debugToggle(0) }
                await step("close merged panel") { coordinator.debugToggle(0) }
                await step("switch to separate") { usageManager.menuBarMode = .separate }
                await step("open provider panel 0") { coordinator.debugToggle(0) }
                await step("close provider panel 0") { coordinator.debugToggle(0) }
                await step("switch to merged") { usageManager.menuBarMode = .merged }
                await step("open merged panel again") { coordinator.debugToggle(0) }
                await step("done") {}
            }
        }
        #endif
        // Fire-and-forget — debounced inside UpdateChecker so this is
        // safe even if the app launches multiple times in 24h.
        Task { await UpdateChecker.shared.checkIfNeeded() }
        // Ask for notification permission on first launch. macOS only
        // shows the prompt once; subsequent calls are cheap no-ops.
        Task { await LimitNotifier.shared.requestAuthorizationIfNeeded() }
    }
}
