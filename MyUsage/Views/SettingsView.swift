import SwiftUI

/// App settings window.
struct SettingsView: View {
    @Environment(UsageManager.self) private var manager

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
        }
        .frame(width: 400, height: 240)
    }

    // MARK: - General

    private func generalTab(refreshInterval: Binding<RefreshInterval>) -> some View {
        Form {
            Picker("Refresh Interval", selection: refreshInterval) {
                ForEach(RefreshInterval.allCases) { interval in
                    Text(interval.displayName).tag(interval)
                }
            }

            // TODO: Launch at Login toggle (Feature 07)
            // Toggle("Launch at Login", isOn: $launchAtLogin)
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Providers

    private var providersTab: some View {
        Form {
            if manager.providers.isEmpty {
                Text("No providers detected yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(manager.providers, id: \.kind) { provider in
                    providerRow(provider)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func providerRow(_ provider: any UsageProvider) -> some View {
        HStack(spacing: 10) {
            Image(systemName: provider.kind.iconName)
                .foregroundStyle(provider.kind.accentColor)
                .frame(width: 20)

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
                set: { provider.isEnabled = $0 }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
    }
}

#Preview {
    SettingsView()
        .environment(UsageManager())
}
