import SwiftUI

/// The menu bar icon that shows in the macOS status bar.
struct MenuBarIcon: View {
    let usageManager: UsageManager

    var body: some View {
        Image(systemName: iconName)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(iconColor)
    }

    private var iconName: String {
        let percent = usageManager.worstUsagePercent
        if percent > 85 {
            return "gauge.with.dots.needle.100percent"
        } else if percent > 60 {
            return "gauge.with.dots.needle.67percent"
        } else if percent > 30 {
            return "gauge.with.dots.needle.33percent"
        } else {
            return "gauge.with.dots.needle.0percent"
        }
    }

    private var iconColor: Color {
        let percent = usageManager.worstUsagePercent
        if percent > 85 { return .red }
        if percent > 60 { return .yellow }
        return .green
    }
}
