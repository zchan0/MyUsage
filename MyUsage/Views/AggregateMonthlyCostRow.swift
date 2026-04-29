import SwiftUI

/// "This month  $112.40  ⊕ 2 devices" row at the bottom of Claude / Codex
/// cards. Mirrors v7 mockup's `.cost-row`. Click the ⊕ pill to open the
/// per-device breakdown popover (unchanged from spec 12).
struct AggregateMonthlyCostRow: View {
    let providerKind: ProviderKind
    let displayed: Double
    let peerCount: Int
    let contributions: [LedgerSync.DeviceContribution]

    @State private var isPopoverShown = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("This month")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            Spacer(minLength: 6)

            Text(ProviderCard.formatCost(displayed))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.primary.opacity(0.95))

            if peerCount > 0 {
                Button { isPopoverShown.toggle() } label: { devicesPill }
                    .buttonStyle(.plain)
                    .help("\(peerCount) other device\(peerCount == 1 ? "" : "s") contributed")
                    .popover(isPresented: $isPopoverShown, arrowEdge: .top) {
                        DeviceBreakdownPopover(
                            providerKind: providerKind,
                            total: displayed,
                            contributions: contributions
                        )
                    }
            }
        }
    }

    private var devicesPill: some View {
        HStack(spacing: 3) {
            Text("⊕")
                .font(.system(size: 10))
            Text(peerCount == 1 ? "1 device" : "\(peerCount + 1) devices")
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .monospacedDigit()
        }
        .foregroundStyle(.secondary.opacity(0.85))
        .padding(.horizontal, 6)
        .padding(.vertical, 1.5)
        .background(
            Color.primary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
    }
}

/// Popover body listing every device that wrote to this (provider, month).
struct DeviceBreakdownPopover: View {
    let providerKind: ProviderKind
    let total: Double
    let contributions: [LedgerSync.DeviceContribution]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ProviderIconTile(kind: providerKind, size: 16, glyph: 10)
                Text("\(providerKind.displayName) — This month")
                    .font(.system(size: 12, weight: .semibold))
            }

            Divider()

            if contributions.isEmpty {
                Text("No contributions yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(contributions) { row in
                        HStack {
                            Image(systemName: row.isSelf ? "laptopcomputer" : "desktopcomputer")
                                .font(.system(size: 10))
                                .foregroundStyle(row.isSelf
                                    ? AnyShapeStyle(.tint)
                                    : AnyShapeStyle(.secondary))
                            Text(row.isSelf ? "\(row.displayName) (this Mac)" : row.displayName)
                                .font(.caption)
                            Spacer()
                            Text(ProviderCard.formatCost(row.costUSD))
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Divider()

            HStack {
                Text("Total")
                    .font(.caption.weight(.medium))
                Spacer()
                Text(ProviderCard.formatCost(total))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }

            Text("Synced via the shared Sync folder. Estimated from each Mac's local session logs × API pricing.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
        .padding(12)
        .frame(width: 260)
    }
}
