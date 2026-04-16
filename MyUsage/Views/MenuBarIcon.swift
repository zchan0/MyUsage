import SwiftUI

/// The menu bar icon that shows in the macOS status bar.
struct MenuBarIcon: View {
    let usageManager: UsageManager

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "chart.bar.fill")

            if let text = usageManager.menuBarDisplayText {
                Text(text)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
            }
        }
    }
}
