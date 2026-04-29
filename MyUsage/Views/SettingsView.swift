import AppKit
import SwiftUI
import ServiceManagement

/// App settings window — restyled to match the popover's visual system.
/// Keeps the existing 4-tab layout (General, Providers, Devices, About);
/// inside each tab the stock `Form` is replaced by `SettingsCard`-based
/// glass sections so the chrome reads consistently with the popover.
struct SettingsView: View {
    @Environment(UsageManager.self) private var manager
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var crashLogStatus: String?

    var body: some View {
        @Bindable var mgr = manager

        TabView {
            generalTab(refreshInterval: $mgr.refreshInterval)
                .tabItem { Label("General", systemImage: "gear") }

            providersTab
                .tabItem { Label("Providers", systemImage: "square.stack.3d.up") }

            DevicesTab()
                .tabItem { Label("Devices", systemImage: "laptopcomputer.and.iphone") }

            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 540, height: 460)
    }

    // MARK: - General

    private func generalTab(refreshInterval: Binding<RefreshInterval>) -> some View {
        @Bindable var mgr = manager

        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {

                SettingsCard("Refresh") {
                    SettingsRow("Interval", caption: "How often providers re-poll their sources.") {
                        Picker("", selection: refreshInterval) {
                            ForEach(RefreshInterval.allCases) { interval in
                                Text(interval.displayName).tag(interval)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 160)
                    }
                }

                SettingsCard("Menu Bar") {
                    SettingsRow("Tracked provider", caption: "Drives the icon's tint and percentage.") {
                        Picker("", selection: $mgr.iconTrackProvider) {
                            Text("None").tag("")
                            ForEach(manager.providers, id: \.kind) { provider in
                                Text(provider.kind.displayName).tag(provider.kind.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 160)
                    }
                }

                SettingsCard("Display") {
                    SettingsRow(
                        "Show estimated monthly cost",
                        caption: "Cost row at the bottom of each provider card."
                    ) {
                        Toggle("", isOn: $mgr.showEstimatedCost)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }

                syncCard

                SettingsCard("System") {
                    SettingsRow(
                        "Launch at Login",
                        caption: "Open MyUsage automatically when you log in."
                    ) {
                        Toggle("", isOn: $launchAtLogin)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .onChange(of: launchAtLogin) { _, newValue in
                                do {
                                    if newValue {
                                        try SMAppService.mainApp.register()
                                    } else {
                                        try SMAppService.mainApp.unregister()
                                    }
                                } catch {
                                    launchAtLogin = SMAppService.mainApp.status == .enabled
                                }
                            }
                    }
                }
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: - Sync card

    private var syncCard: some View {
        SettingsCard("Sync Folder") {
            VStack(alignment: .leading, spacing: 0) {
                SettingsRow("Folder", caption: manager.ledger.syncFolderDisplayPath) {
                    HStack(spacing: 6) {
                        if manager.ledger.canRevealSyncFolder {
                            Button("Reveal") {
                                manager.ledger.revealSyncFolderInFinder()
                            }
                            .controlSize(.small)
                        }
                        Button("Choose…") {
                            Task { await manager.ledger.chooseSyncFolder() }
                        }
                        .controlSize(.small)
                    }
                }

                CardDivider()

                HStack(alignment: .center, spacing: 8) {
                    Circle()
                        .fill(syncStatusColor(manager.ledger.syncFolderStatusKind))
                        .frame(width: 7, height: 7)
                    Text(manager.ledger.syncFolderStatusText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.vertical, 8)
            }
        }
    }

    private func syncStatusColor(_ kind: LedgerSync.SyncFolderStatusKind) -> Color {
        switch kind {
        case .idle: .secondary
        case .available: Color(hue: 145.0/360.0, saturation: 0.45, brightness: 0.55)
        case .warning: Color(hue: 38.0/360.0, saturation: 0.92, brightness: 0.62)
        case .error: Color(hue: 8.0/360.0, saturation: 0.78, brightness: 0.62)
        }
    }

    // MARK: - Providers

    private var providersTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SettingsCard("Providers · drag to reorder") {
                    VStack(alignment: .leading, spacing: 0) {
                        let kinds = manager.providerOrder.compactMap { raw in
                            manager.providers.first { $0.kind.rawValue == raw }
                        }
                        ForEach(Array(kinds.enumerated()), id: \.element.kind) { index, provider in
                            providerRow(provider)
                            if index < kinds.count - 1 {
                                CardDivider()
                            }
                        }
                    }
                }

                Text("Reordering will be available again in a future update — for now, drag remains in the legacy list. Toggle providers off to hide them from the menu-bar popover.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
    }

    private func providerRow(_ provider: any UsageProvider) -> some View {
        HStack(spacing: 12) {
            ProviderIconTile(kind: provider.kind, size: 24, glyph: 14)

            VStack(alignment: .leading, spacing: 2) {
                Text(provider.kind.displayName)
                    .font(.system(size: 12.5, weight: .semibold))
                detectionLabel(provider)
            }

            Spacer(minLength: 12)

            Toggle("", isOn: Binding(
                get: { provider.isEnabled },
                set: { newValue in
                    provider.isEnabled = newValue
                    UserDefaults.standard.set(newValue, forKey: "provider.\(provider.kind.rawValue).enabled")
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func detectionLabel(_ provider: any UsageProvider) -> some View {
        if provider.isAvailable {
            HStack(spacing: 4) {
                Circle()
                    .fill(Color(hue: 145.0/360.0, saturation: 0.45, brightness: 0.55))
                    .frame(width: 5, height: 5)
                Text("Detected")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Not found")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - About

    private var aboutTab: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 10) {
                    if let icon = NSApp.applicationIconImage {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 72, height: 72)
                    } else {
                        Image(systemName: "chart.bar.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.tint)
                    }

                    VStack(spacing: 2) {
                        Text("MyUsage")
                            .font(.system(size: 17, weight: .semibold))
                        Text("Version \(AppInfo.version)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    Text("Monitor AI coding tool usage from your menu bar.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Link(destination: URL(string: "https://github.com/zchan0/MyUsage")!) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 10))
                            Text("GitHub")
                                .font(.system(size: 11, weight: .medium))
                        }
                    }
                    .foregroundStyle(.tint)
                }
                .padding(.top, 8)
                .frame(maxWidth: .infinity)

                SettingsCard("Help & Feedback") {
                    VStack(alignment: .leading, spacing: 0) {
                        SettingsRow(
                            "Report an issue",
                            caption: "Opens GitHub Issues with version and macOS pre-filled."
                        ) {
                            Button("Open") { SupportActions.openIssueWithDiagnostics() }
                                .controlSize(.small)
                        }

                        CardDivider()

                        SettingsRow(
                            "Copy crash log",
                            caption: crashLogStatus
                                ?? "Scans ~/Library/Logs/DiagnosticReports for the newest MyUsage crash."
                        ) {
                            Button("Copy") { copyLatestCrashLog() }
                                .controlSize(.small)
                        }
                    }
                }
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
    }

    private func copyLatestCrashLog() {
        switch SupportActions.copyLatestCrashLogToClipboard() {
        case .copied(let filename):
            crashLogStatus = "Copied \(filename) to clipboard."
        case .none:
            crashLogStatus = "No MyUsage crash logs found — nothing to report."
        case .failed(let message):
            crashLogStatus = "Could not read crash log: \(message)"
        }
    }
}

// MARK: - Support actions

private enum SupportActions {
    enum CrashLogResult {
        case copied(filename: String)
        case none
        case failed(String)
    }

    static func openIssueWithDiagnostics() {
        var components = URLComponents(string: "https://github.com/zchan0/MyUsage/issues/new")!
        components.queryItems = [
            URLQueryItem(name: "title", value: "[bug] "),
            URLQueryItem(name: "body", value: issueBody())
        ]
        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }

    static func copyLatestCrashLogToClipboard() -> CrashLogResult {
        let reportsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)

        let candidates: [URL]
        do {
            candidates = try FileManager.default.contentsOfDirectory(
                at: reportsDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ).filter { url in
                let name = url.lastPathComponent
                guard name.hasPrefix("MyUsage") else { return false }
                let ext = url.pathExtension.lowercased()
                return ext == "ips" || ext == "crash"
            }
        } catch {
            return .failed(error.localizedDescription)
        }

        guard let latest = candidates.max(by: { a, b in
            (a.modificationDate ?? .distantPast) < (b.modificationDate ?? .distantPast)
        }) else {
            return .none
        }

        do {
            let contents = try String(contentsOf: latest, encoding: .utf8)
            let payload = "\(issueBody())\n\n---\n\n\(contents)"
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(payload, forType: .string)
            return .copied(filename: latest.lastPathComponent)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func issueBody() -> String {
        let macOS = ProcessInfo.processInfo.operatingSystemVersionString
        return """
        **What happened?**
        <!-- describe the issue -->

        **Steps to reproduce**
        1.
        2.

        **Expected vs actual**

        ---
        - MyUsage version: \(AppInfo.version)
        - macOS: \(macOS)
        """
    }
}

private extension URL {
    var modificationDate: Date? {
        (try? resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

#Preview {
    SettingsView()
        .environment(UsageManager())
}
