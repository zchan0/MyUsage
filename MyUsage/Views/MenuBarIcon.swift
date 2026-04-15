import SwiftUI

/// The menu bar icon that shows in the macOS status bar.
struct MenuBarIcon: View {
    let usageManager: UsageManager

    var body: some View {
        Image(systemName: iconName)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(iconColor)
    }

    private var worstPercent: Double {
        usageManager.worstUsagePercent
    }

    private var iconName: String {
        if worstPercent > 85 { return "chart.bar.fill" }
        if worstPercent > 60 { return "chart.bar.fill" }
        return "chart.bar.fill"
    }

    private var iconColor: Color {
        if worstPercent > 85 { return .red }
        if worstPercent > 60 { return .yellow }
        return .green
    }
}
