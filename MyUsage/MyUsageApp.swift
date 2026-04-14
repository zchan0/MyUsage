import SwiftUI

@main
struct MyUsageApp: App {
    @State private var usageManager = UsageManager()

    var body: some Scene {
        MenuBarExtra {
            UsagePopover()
                .environment(usageManager)
        } label: {
            MenuBarIcon(usageManager: usageManager)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(usageManager)
        }
    }
}
