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
    let usageManager = UsageManager()
    let updateChecker = UpdateChecker.shared

    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController = StatusItemController(manager: usageManager, updateChecker: updateChecker)
        usageManager.startTimer()

        Task { await usageManager.refreshAll() }
        // Fire-and-forget — debounced inside UpdateChecker so this is
        // safe even if the app launches multiple times in 24h.
        Task { await UpdateChecker.shared.checkIfNeeded() }
        // Ask for notification permission on first launch. macOS only
        // shows the prompt once; subsequent calls are cheap no-ops.
        Task { await LimitNotifier.shared.requestAuthorizationIfNeeded() }
    }
}
