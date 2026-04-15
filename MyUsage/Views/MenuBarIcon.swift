import SwiftUI

/// The menu bar icon that shows in the macOS status bar.
struct MenuBarIcon: View {
    let usageManager: UsageManager

    var body: some View {
        let percent = usageManager.trackedUsagePercent
        let color = iconColor(for: percent)

        Image(systemName: "gauge.with.needle.fill")
            .symbolRenderingMode(usageManager.iconFollowsUsage ? .palette : .monochrome)
            .foregroundStyle(color, color.opacity(0.4))
    }

    private func iconColor(for percent: Double) -> Color {
        guard usageManager.iconFollowsUsage else { return .primary }
        if percent > 85 { return .red }
        if percent > 60 { return .yellow }
        return .green
    }
}
