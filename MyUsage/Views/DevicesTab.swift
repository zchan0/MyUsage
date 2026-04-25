import SwiftUI

/// Settings → Devices. Lists every Mac that has contributed to the ledger,
/// with per-month totals and a Forget button for peers whose rows should
/// stop counting locally. See spec 12.
struct DevicesTab: View {
    @Environment(UsageManager.self) private var manager

    @State private var rows: [DeviceRow] = []
    @State private var isLoading = false
    @State private var forgetTarget: DeviceRow?

    struct DeviceRow: Identifiable, Equatable {
        let deviceId: String
        let displayName: String
        let isSelf: Bool
        let claudeUSD: Double
        let codexUSD: Double

        var id: String { deviceId }
        var totalUSD: Double { claudeUSD + codexUSD }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow

            if rows.isEmpty {
                emptyState
            } else {
                columnHeader
                List {
                    ForEach(rows) { row in
                        deviceListRow(row)
                    }
                }
                .listStyle(.inset)
            }

            footnote
        }
        .padding()
        .task { await reload() }
        .confirmationDialog(
            forgetTarget.map { "Forget \($0.displayName)?" } ?? "Forget device?",
            isPresented: Binding(
                get: { forgetTarget != nil },
                set: { if !$0 { forgetTarget = nil } }
            ),
            titleVisibility: .visible,
            presenting: forgetTarget
        ) { row in
            Button("Forget", role: .destructive) {
                manager.ledger.forgetPeer(deviceID: row.deviceId)
                Task { await reload() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Stops counting this device on this Mac and removes its files from the Sync folder. If the device is still active, it will reappear next time it publishes.")
        }
    }

    // MARK: - Subviews

    private var headerRow: some View {
        HStack(spacing: 8) {
            Text("Devices")
                .font(.headline)
            Spacer()
            if let last = manager.ledger.lastSyncedAt {
                Text(last, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    + Text(" since last sync")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await reload(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                    .rotationEffect(.degrees(isLoading ? 360 : 0))
                    .animation(
                        isLoading
                            ? .linear(duration: 1).repeatForever(autoreverses: false)
                            : .default,
                        value: isLoading
                    )
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
            .help("Publish this Mac's ledger files and import peer updates now.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "folder.badge.person.crop")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text("No synced devices yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Point each Mac at the same Sync folder to aggregate monthly costs.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 140)
    }

    /// Width of each numeric column. Keeps rows + header aligned without
    /// switching to `Table`, which is noticeably heavier in Settings.
    private let costColumnWidth: CGFloat = 64
    private let forgetColumnWidth: CGFloat = 60

    private var columnHeader: some View {
        HStack(spacing: 10) {
            Text("Device")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Claude")
                .frame(width: costColumnWidth, alignment: .trailing)
            Text("Codex")
                .frame(width: costColumnWidth, alignment: .trailing)
            Text("Total")
                .frame(width: costColumnWidth, alignment: .trailing)
            Spacer().frame(width: forgetColumnWidth)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
    }

    private func deviceListRow(_ row: DeviceRow) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: row.isSelf ? "laptopcomputer" : "desktopcomputer")
                    .foregroundStyle(row.isSelf
                        ? AnyShapeStyle(.tint)
                        : AnyShapeStyle(.secondary))

                VStack(alignment: .leading, spacing: 2) {
                    Text(row.isSelf ? "\(row.displayName) (this Mac)" : row.displayName)
                        .font(.system(size: 12))
                    Text(row.deviceId.prefix(8))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            costCell(row.claudeUSD)
            costCell(row.codexUSD)
            costCell(row.totalUSD, emphasised: true)

            if row.isSelf {
                Spacer().frame(width: forgetColumnWidth)
            } else {
                Button("Forget") {
                    forgetTarget = row
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .frame(width: forgetColumnWidth, alignment: .trailing)
                .help("Stop counting this device and remove its files from the Sync folder.")
            }
        }
        .padding(.vertical, 2)
    }

    private func costCell(_ amount: Double, emphasised: Bool = false) -> some View {
        Text(amount > 0 ? ProviderCard.formatCost(amount) : "—")
            .font(.system(
                size: 11,
                weight: emphasised ? .semibold : .medium,
                design: .monospaced
            ))
            .foregroundStyle(emphasised
                ? AnyShapeStyle(.primary)
                : AnyShapeStyle(.secondary))
            .frame(width: costColumnWidth, alignment: .trailing)
    }

    private var footnote: some View {
        Text("Costs are the sum of Claude Code + Codex monthly totals reported by each Mac. Each Mac only writes to its own subfolder inside the shared Sync folder. Forget removes both the local row and the device's folder in the Sync folder.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    // MARK: - Data

    private func reload(force: Bool = false) async {
        isLoading = true
        defer { isLoading = false }

        if force {
            await manager.ledger.syncNow()
        }

        let monthKey = LedgerCalendar.monthKey(for: .now)
        let store = manager.ledger.store
        let selfID = manager.ledger.selfDeviceID

        let ids = (try? store.knownDeviceIDs()) ?? []
        var claudeById: [String: Double] = [:]
        var codexById: [String: Double] = [:]

        let claudeTotals = (try? store.monthlyTotalsByDevice(
            provider: .claude,
            monthKey: monthKey
        )) ?? []
        for t in claudeTotals { claudeById[t.deviceId] = t.costUSD }

        let codexTotals = (try? store.monthlyTotalsByDevice(
            provider: .codex,
            monthKey: monthKey
        )) ?? []
        for t in codexTotals { codexById[t.deviceId] = t.costUSD }

        let combinedIds = Set(ids)
            .union(claudeById.keys)
            .union(codexById.keys)
            .union([selfID])

        let newRows = combinedIds.map { id in
            DeviceRow(
                deviceId: id,
                displayName: manager.ledger.displayName(for: id),
                isSelf: id == selfID,
                claudeUSD: claudeById[id] ?? 0,
                codexUSD: codexById[id] ?? 0
            )
        }
        .sorted { a, b in
            if a.isSelf != b.isSelf { return a.isSelf }
            return a.totalUSD > b.totalUSD
        }

        rows = newRows
    }
}
