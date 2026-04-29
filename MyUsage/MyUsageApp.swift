import SwiftUI

@main
struct MyUsageApp: App {
    @State private var usageManager = UsageManager()
    @State private var updateChecker = UpdateChecker.shared

    var body: some Scene {
        MenuBarExtra {
            UsagePopover()
                .environment(usageManager)
                .environment(updateChecker)
        } label: {
            MenuBarIcon(usageManager: usageManager)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(usageManager)
                .environment(updateChecker)
        }
    }

    init() {
        // Fire-and-forget — debounced inside UpdateChecker so this is
        // safe even if the app launches multiple times in 24h.
        Task { await UpdateChecker.shared.checkIfNeeded() }
    }
}
