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

            aboutTab
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 420, height: 340)
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

            Section("Menu Bar Icon") {
                Picker("Show usage", selection: $mgr.iconTrackProvider) {
                    Text("Icon only").tag("")
                    ForEach(manager.providers, id: \.kind) { provider in
                        Text(provider.kind.displayName).tag(provider.kind.rawValue)
                    }
                }
            }

            Section("Display") {
                Toggle("Show estimated monthly cost", isOn: $mgr.showEstimatedCost)
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

            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
            Text("Version \(version)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Monitor AI coding tool usage from your menu bar.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Link("GitHub", destination: URL(string: "https://github.com/zchan0/MyUsage")!)
                .font(.caption)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

#Preview {
    SettingsView()
        .environment(UsageManager())
}
