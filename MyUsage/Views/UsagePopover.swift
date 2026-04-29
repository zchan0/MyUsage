import SwiftUI

/// Main popover content shown when clicking the menu bar icon.
///
/// Visual structure follows `docs/ui-mockups/popover-glassy-v7.html`:
///   · Header: wordmark · "X ago" (mono) · refresh
///   · Card stack: one ProviderCard per enabled provider, 7pt gap,
///     no global divider (each card carries its own border)
///   · Footer: Quit (left) · settings (right), with a single
///     hairline above
struct UsagePopover: View {
    @Environment(UsageManager.self) private var manager
    @Environment(UpdateChecker.self) private var updateChecker

    var body: some View {
        VStack(spacing: 0) {
            header

            if enabledProviders.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(enabledProviders, id: \.kind) { provider in
                            ProviderCard(provider: provider)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
                    .padding(.bottom, 12)
                }
            }

            footerDivider
            footer
        }
        .frame(width: 340)
        .task(id: "init") {
            manager.startTimer()
        }
        .onAppear {
            Task { await manager.refreshAll() }
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: 8) {
            Text("MyUsage")
                .font(.system(size: 13.5, weight: .semibold))
                .tracking(-0.2)

            Spacer()

            if let lastRefreshed = manager.lastRefreshed {
                (
                    Text(lastRefreshed, style: .relative)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .monospacedDigit()
                    + Text(" ago")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                )
                .foregroundStyle(.secondary.opacity(0.7))
            }

            Button {
                Task { await manager.refreshAll() }
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13))
                        .rotationEffect(.degrees(manager.isRefreshing ? 360 : 0))
                        .animation(
                            manager.isRefreshing
                                ? .linear(duration: 1).repeatForever(autoreverses: false)
                                : .default,
                            value: manager.isRefreshing
                        )

                    if updateChecker.updateAvailable != nil {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                            .overlay(
                                Circle()
                                    .stroke(Color.accentColor.opacity(0.25), lineWidth: 2)
                            )
                            .offset(x: 4, y: -3)
                            .help("An update is available — open Settings → About to view it.")
                    }
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(manager.isRefreshing)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 11)
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

    private var footerDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: 0.5)
    }

    private var footer: some View {
        HStack {
            Spacer()

            SettingsLink {
                Image(systemName: "gear")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NSApp.activate(ignoringOtherApps: true)
                }
            })
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Helpers

    private var enabledProviders: [any UsageProvider] {
        manager.orderedProviders.filter { $0.isEnabled }
    }
}

#Preview {
    UsagePopover()
        .environment(UsageManager())
        .environment(UpdateChecker())
}
