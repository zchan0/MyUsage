import SwiftUI

/// Main popover content shown when clicking the menu bar icon.
struct UsagePopover: View {
    @Environment(UsageManager.self) private var manager

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            Divider()
                .padding(.horizontal, 12)

            // Provider cards
            if enabledProviders.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(enabledProviders, id: \.kind) { provider in
                            ProviderCard(provider: provider)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
            }

            Divider()
                .padding(.horizontal, 12)

            // Footer
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .frame(width: 340)
        .task {
            await manager.refreshAll()
            manager.startTimer()
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack {
            Text("MyUsage")
                .font(.system(size: 16, weight: .semibold))

            Spacer()

            if let lastRefreshed = manager.lastRefreshed {
                Text(lastRefreshed, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    + Text(" ago")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await manager.refreshAll() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
                    .rotationEffect(manager.isRefreshing ? .degrees(360) : .zero)
                    .animation(
                        manager.isRefreshing
                            ? .linear(duration: 1).repeatForever(autoreverses: false)
                            : .default,
                        value: manager.isRefreshing
                    )
            }
            .buttonStyle(.plain)
            .disabled(manager.isRefreshing)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)

            Text("No providers detected")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Install Claude Code, Codex, Cursor, or Antigravity to get started.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "gear")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Helpers

    private var enabledProviders: [any UsageProvider] {
        manager.providers.filter { $0.isEnabled }
    }
}

#Preview {
    UsagePopover()
        .environment(UsageManager())
}
