import SwiftUI

/// Settings → Devices. Lists every Mac that has contributed to the ledger,
/// with per-month totals and a Forget button for peers whose rows should
/// stop counting locally. See `specs/12a-sync-folder.md`.
///
/// Restyled to match the popover / SettingsCard visual system: glass card
/// containing a column-aligned device list, mono cost numerals, hairline
/// dividers between rows. Header shows last-sync time + manual Sync Now.
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
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if rows.isEmpty {
                    emptyCard
                } else {
                    devicesCard
                }

                Text("Costs are the sum of Claude Code + Codex monthly totals reported by each Mac. Each Mac only writes to its own subfolder. Forget removes both the local row and the device's folder in the Sync folder.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
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

    // MARK: - Cards

    private var devicesCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 0) {
                cardHeader
                CardDivider()
                columnHeader
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { CardDivider() }
                    deviceListRow(row)
                }
            }
        }
    }

    private var emptyCard: some View {
        SettingsCard {
            VStack(spacing: 8) {
                Image(systemName: "folder.badge.person.crop")
                    .font(.system(size: 26))
                    .foregroundStyle(.tertiary)
                Text("No synced devices yet")
                    .font(.system(size: 13, weight: .semibold))
                Text("Point each Mac at the same Sync folder to aggregate monthly costs.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Sync now") {
                    Task { await reload(force: true) }
                }
                .controlSize(.small)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, minHeight: 140)
            .padding(.vertical, 16)
        }
    }

    private var cardHeader: some View {
        HStack(spacing: 8) {
            Text("Devices")
                .font(.system(size: 13, weight: .semibold))

            if let last = manager.ledger.lastSyncedAt {
                Text("·")
                    .foregroundStyle(.tertiary)
                (
                    Text(last, style: .relative)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .monospacedDigit()
                    + Text(" since last sync")
                        .font(.system(size: 10))
                )
                .foregroundStyle(.secondary.opacity(0.7))
            }

            Spacer()

            Button {
                Task { await reload(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
                    .rotationEffect(.degrees(isLoading ? 360 : 0))
                    .animation(
                        isLoading
                            ? .linear(duration: 1).repeatForever(autoreverses: false)
                            : .default,
                        value: isLoading
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(isLoading)
            .help("Publish this Mac's ledger files and import peer updates now.")
        }
        .padding(.vertical, 8)
    }

    // MARK: - Column layout

    /// Column widths for the device list. Kept narrow so 4 columns fit
    /// in the 540pt Settings window without crowding the device-name slot.
    private let claudeColWidth: CGFloat = 64
    private let codexColWidth: CGFloat = 64
    private let totalColWidth: CGFloat = 64
    private let actionColWidth: CGFloat = 56

    private var columnHeader: some View {
        HStack(spacing: 10) {
            Text("Device")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Claude")
                .frame(width: claudeColWidth, alignment: .trailing)
            Text("Codex")
                .frame(width: codexColWidth, alignment: .trailing)
            Text("Total")
                .frame(width: totalColWidth, alignment: .trailing)
            Spacer().frame(width: actionColWidth)
        }
        .font(.system(size: 9, weight: .semibold))
        .tracking(0.6)
        .textCase(.uppercase)
        .foregroundStyle(.secondary.opacity(0.7))
        .padding(.vertical, 6)
    }

    private func deviceListRow(_ row: DeviceRow) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: deviceSymbol(for: row))
                    .font(.system(size: 13))
                    .foregroundStyle(row.isSelf
                        ? AnyShapeStyle(.tint)
                        : AnyShapeStyle(.secondary))
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(row.displayName)
                            .font(.system(size: 12.5, weight: .medium))
                        if row.isSelf {
                            Text("THIS MAC")
                                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                                .tracking(0.5)
                                .foregroundStyle(.tint)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(
                                    .tint.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 3, style: .continuous)
                                )
                        }
                    }
                    Text(row.deviceId.prefix(8))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            costCell(row.claudeUSD, width: claudeColWidth)
            costCell(row.codexUSD, width: codexColWidth)
            costCell(row.totalUSD, width: totalColWidth, emphasised: true)

            if row.isSelf {
                Spacer().frame(width: actionColWidth)
            } else {
                Button("Forget") { forgetTarget = row }
                    .font(.system(size: 11))
                    .buttonStyle(.borderless)
                    .frame(width: actionColWidth, alignment: .trailing)
                    .help("Stop counting this device and remove its files from the Sync folder.")
            }
        }
        .padding(.vertical, 8)
    }

    private func costCell(_ amount: Double, width: CGFloat, emphasised: Bool = false) -> some View {
        Text(amount > 0 ? ProviderCard.formatCost(amount) : "—")
            .font(.system(
                size: 11,
                weight: emphasised ? .semibold : .regular,
                design: .monospaced
            ))
            .monospacedDigit()
            .foregroundStyle(emphasised
                ? AnyShapeStyle(.primary)
                : AnyShapeStyle(.secondary))
            .frame(width: width, alignment: .trailing)
    }

    private func deviceSymbol(for row: DeviceRow) -> String {
        let name = row.displayName.lowercased()
        if name.contains("mac mini") || name.contains("mini") { return "macmini" }
        if name.contains("studio") { return "macstudio" }
        if name.contains("imac") { return "desktopcomputer" }
        if row.isSelf { return "laptopcomputer" }
        return "desktopcomputer"
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
