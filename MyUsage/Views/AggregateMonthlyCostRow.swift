import SwiftUI

/// "This month ~$12.34  ⊕ 2" row shown on Claude / Codex cards when the
/// multi-device ledger has visible contributions. Clicking the ⊕ badge
/// opens a popover with the per-device breakdown — see spec 12.
struct AggregateMonthlyCostRow: View {
    let providerKind: ProviderKind
    let displayed: Double
    let peerCount: Int
    let contributions: [LedgerSync.DeviceContribution]

    @State private var isPopoverShown = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "dollarsign.circle")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            Text("This month")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Image(systemName: "info.circle")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .help(ProviderCard.aggregateTooltip)

            Spacer()

            Text(ProviderCard.formatCost(displayed))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)

            if peerCount > 0 {
                Button {
                    isPopoverShown.toggle()
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 10))
                        Text("\(peerCount)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                    }
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.tint.opacity(0.10), in: Capsule())
                }
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
}

/// Popover body listing every device that wrote to this (provider, month).
struct DeviceBreakdownPopover: View {
    let providerKind: ProviderKind
    let total: Double
    let contributions: [LedgerSync.DeviceContribution]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ProviderIcon(kind: providerKind, size: 14)
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
