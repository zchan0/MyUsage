import SwiftUI

/// The summary strip at the top of the Overview tab: three stat tiles
/// answering the glance questions before any card is read —
///
///   ┌──────────────┬──────────────┬──────────────┐
///   │ TODAY        │ JULY         │ NEXT RESET   │
///   │ ~$6.84       │ ~$114.21     │ 2h 14m       │
///   │ ↑38% vs 7d   │ Jun ~$89     │ Claude · 5h  │
///   └──────────────┴──────────────┴──────────────┘
///
/// Shown only when ≥ 2 providers are enabled — with a single provider the
/// strip would just repeat that provider's own card. Cost tiles addition-
/// ally honor the `showEstimatedCost` toggle ("no cost UI" means none
/// anywhere); the reset tile survives on its own.
///
/// Deltas render in neutral secondary — spending more isn't styled as an
/// alarm, it's just context (user decision, 2026-07).
struct OverviewStatTiles: View {
    @Environment(UsageManager.self) private var manager

    let providers: [any UsageProvider]

    var body: some View {
        let tiles = buildTiles()
        if providers.count >= 2, !tiles.isEmpty {
            HStack(spacing: 7) {
                ForEach(tiles) { tile in
                    StatTile(tile: tile)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 9)
        }
    }

    // MARK: - Tile assembly

    private struct TileModel: Identifiable {
        let id: String
        let label: String
        let value: String
        let caption: String?
    }

    private func buildTiles() -> [TileModel] {
        var tiles: [TileModel] = []

        if manager.showEstimatedCost {
            tiles.append(todayTile())
            if let month = monthTile() { tiles.append(month) }
        }
        if let reset = resetTile() { tiles.append(reset) }

        return tiles
    }

    private func todayTile() -> TileModel {
        let total = OverviewSummary.todayTotal(dailyCosts: manager.ledger.dailyCosts)
        let caption = OverviewSummary.deltaCaption(
            today: total,
            average: OverviewSummary.trailingDailyAverage(dailyCosts: manager.ledger.dailyCosts)
        ) ?? "est. all tools"
        return TileModel(
            id: "today",
            label: "Today",
            value: ProviderCardCostRow.formatCost(total),
            caption: caption
        )
    }

    private func monthTile() -> TileModel? {
        let monthKey = LedgerCalendar.monthKey(for: .now)
        let total = OverviewSummary.monthTotal(
            monthlyTotals: manager.ledger.monthlyTotals, monthKey: monthKey
        ) ?? 0

        var caption: String?
        let prevKey = OverviewSummary.previousMonthKey()
        if let prev = OverviewSummary.monthTotal(
            monthlyTotals: manager.ledger.monthlyTotals, monthKey: prevKey
        ) {
            caption = "\(Self.monthName(for: prevKey)) \(ProviderCardCostRow.formatCost(prev))"
        }

        return TileModel(
            id: "month",
            label: Self.monthName(for: monthKey),
            value: ProviderCardCostRow.formatCost(total),
            caption: caption ?? "est. all tools"
        )
    }

    private func resetTile() -> TileModel? {
        var candidates: [OverviewSummary.ResetCandidate] = []
        for provider in providers {
            guard let snapshot = provider.snapshot else { continue }
            let name = provider.kind.shortName
            if let session = snapshot.sessionUsage {
                candidates.append(.init(providerName: name, windowLabel: "5h", resetsAt: session.resetsAt))
            }
            if let weekly = snapshot.weeklyUsage {
                candidates.append(.init(providerName: name, windowLabel: "weekly", resetsAt: weekly.resetsAt))
            }
            if provider.kind == .cursor {
                candidates.append(.init(providerName: name, windowLabel: "cycle", resetsAt: snapshot.billingCycleEnd))
            }
        }
        guard let next = OverviewSummary.nextReset(from: candidates) else { return nil }
        return TileModel(
            id: "reset",
            label: "Next reset",
            value: OverviewSummary.shortCountdown(until: next.resetsAt),
            caption: "\(next.providerName) · \(next.windowLabel)"
        )
    }

    /// "Jul" for a `YYYY-MM` key, in the user's locale.
    private static func monthName(for monthKey: String) -> String {
        let parts = monthKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return monthKey }
        var comps = DateComponents()
        comps.year = parts[0]
        comps.month = parts[1]
        guard let date = LedgerCalendar.utc.date(from: comps) else { return monthKey }
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.setLocalizedDateFormatFromTemplate("MMM")
        return formatter.string(from: date)
    }

    // MARK: - Tile view

    private struct StatTile: View {
        let tile: TileModel

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(tile.label.uppercased())
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(1.0)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                Text(tile.value)
                    .font(.system(size: 14.5, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.primary.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                if let caption = tile.caption {
                    Text(caption)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary.opacity(0.75))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.background.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            )
        }
    }
}
