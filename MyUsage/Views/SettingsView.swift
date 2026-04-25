import AppKit
import SwiftUI
import ServiceManagement

/// App settings window.
struct SettingsView: View {
    @Environment(UsageManager.self) private var manager
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        @Bindable var mgr = manager

        TabView {
            generalTab(refreshInterval: $mgr.refreshInterval)
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            providersTab
                .tabItem {
                    Label("Providers", systemImage: "square.stack.3d.up")
                }

            DevicesTab()
                .tabItem {
                    Label("Devices", systemImage: "laptopcomputer.and.iphone")
                }

            aboutTab
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 540, height: 400)
    }

    // MARK: - General

    private func generalTab(refreshInterval: Binding<RefreshInterval>) -> some View {
        @Bindable var mgr = manager

        return Form {
            Section("Refresh") {
                Picker("Interval", selection: refreshInterval) {
                    ForEach(RefreshInterval.allCases) { interval in
                        Text(interval.displayName).tag(interval)
                    }
                }
            }

            Section("MenuBar Icon") {
                Picker("Track provider", selection: $mgr.iconTrackProvider) {
                    Text("None").tag("")
                    ForEach(manager.providers, id: \.kind) { provider in
                        Text(provider.kind.displayName).tag(provider.kind.rawValue)
                    }
                }
            }

            Section("Display") {
                Toggle("Show estimated monthly cost", isOn: $mgr.showEstimatedCost)
            }

            Section("Sync") {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Folder")
                    Spacer()
                    Text(manager.ledger.syncFolderDisplayPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose…") {
                        Task { await manager.ledger.chooseSyncFolder() }
                    }
                }

                HStack(alignment: .center, spacing: 6) {
                    Circle()
                        .fill(syncStatusColor(manager.ledger.syncFolderStatusKind))
                        .frame(width: 8, height: 8)
                    Text(manager.ledger.syncFolderStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if manager.ledger.canRevealSyncFolder {
                    Button("Reveal in Finder") {
                        manager.ledger.revealSyncFolderInFinder()
                    }
                    .font(.caption)
                }
            }

            Section("System") {
                Toggle("Launch at Login", isOn: $launchAtLogin)
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
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Providers

    private var providersTab: some View {
        @Bindable var mgr = manager

        return Form {
            Section {
                List {
                    ForEach(manager.providerOrder, id: \.self) { kindRaw in
                        if let provider = manager.providers.first(where: { $0.kind.rawValue == kindRaw }) {
                            providerRow(provider)
                        }
                    }
                    .onMove { source, destination in
                        manager.moveProvider(from: source, to: destination)
                    }
                }
            } header: {
                Text("Drag to reorder")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func providerRow(_ provider: any UsageProvider) -> some View {
        HStack(spacing: 10) {
            ProviderIcon(kind: provider.kind, size: 20)

            Text(provider.kind.displayName)

            Spacer()

            if provider.isAvailable {
                Text("Detected")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Text("Not found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
    }

    // MARK: - About

    private func syncStatusColor(_ kind: LedgerSync.SyncFolderStatusKind) -> Color {
        switch kind {
        case .idle:
            return .secondary
        case .available:
            return .green
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }

    private var aboutTab: some View {
        VStack(spacing: 12) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 80, height: 80)
            } else {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
            }

            Text("MyUsage")
                .font(.title2.bold())

            Text("Version \(AppInfo.version)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Monitor AI coding tool usage from your menu bar.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Link("GitHub", destination: URL(string: "https://github.com/zchan0/MyUsage")!)
                .font(.caption)

            Divider().padding(.vertical, 4)

            VStack(spacing: 6) {
                Text("Help & Feedback")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button("Report an Issue", action: SupportActions.openIssueWithDiagnostics)
                    Button(crashLogButtonTitle, action: copyLatestCrashLog)
                }
                .controlSize(.small)

                Text(crashLogStatus ?? "Includes app version + macOS version. No data is sent automatically.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(minHeight: 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    @State private var crashLogStatus: String?

    private var crashLogButtonTitle: String { "Copy Latest Crash Log" }

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
