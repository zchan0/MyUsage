import SwiftUI

/// Small badges that appear in `ProviderCard`'s head row. Kept as
/// independent `View` structs so each one is trivially previewable and
/// testable in isolation, and so the parent card file stays focused on
/// orchestration rather than badge styling.

/// Amber dot beside a provider name when the snapshot is stale.
struct StaleDot: View {
    var body: some View {
        Circle()
            .fill(Color.orange)
            .frame(width: 6, height: 6)
            .overlay(
                Circle().stroke(Color.orange.opacity(0.18), lineWidth: 2)
            )
            .help("Last refresh failed — showing cached data")
    }
}

/// Small monospaced pill for the plan label ("Pro" / "Max" / "Plus" / "IDE off").
/// Same shape as the ⊕ devices pill so the card head stays visually rhyming.
struct PlanPill: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(.secondary.opacity(0.78))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Color.primary.opacity(0.06),
                in: Capsule()
            )
    }
}

/// Periwinkle "LIVE" badge for Antigravity when the IDE is running.
struct LiveBadge: View {
    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(ProviderKind.antigravity.brandTileColor)
                .frame(width: 5, height: 5)
            Text("LIVE")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.4)
        }
        .foregroundStyle(ProviderKind.antigravity.brandTileColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            ProviderKind.antigravity.brandTileColor.opacity(0.14),
            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
        )
    }
}
