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
                // Plain VStack — NO ScrollView. The popover panel sizes itself
                // to this content's intrinsic height, so a ScrollView would
                // have no height to fill and collapse to zero (the cards would
                // vanish). A plain VStack sizes to its cards and renders
                // reliably; there are only ever a handful of provider cards,
                // so scrolling buys nothing.
                VStack(spacing: 7) {
                    ForEach(enabledProviders, id: \.kind) { provider in
                        providerSlot(for: provider)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 2)
                .padding(.bottom, 12)
            }

            footerDivider
            footer
        }
        .frame(width: 340)
        // Take the content's ideal height. The hosting panel measures this
        // (via onSizeChange) and resizes its window to match exactly — both
        // growing and shrinking — so there's never a leftover gap. Chrome
        // (rounded material + clear window + shadow) is owned by PopoverPanel.
        .fixedSize(horizontal: false, vertical: true)
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
                        // `.resizable().scaledToFit()` makes the symbol a
                        // pure shape that fills its frame, geometrically
                        // centered — so rotating around .center spins it in
                        // place. A font-sized symbol sits on a text baseline
                        // offset from the frame's geometric center, so
                        // rotating it orbits / wobbles (the "displacement"
                        // motion, worse since the macOS 26 symbol-rendering
                        // change). resizable removes the baseline entirely.
                        .resizable()
                        .scaledToFit()
                        .fontWeight(.regular)
                        .frame(width: 13, height: 13)
                        .rotationEffect(.degrees(manager.isRefreshing ? 360 : 0), anchor: .center)
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

    @ViewBuilder
    private func providerSlot(for provider: any UsageProvider) -> some View {
        ProviderCard(provider: provider)
    }
}

#Preview {
    UsagePopover()
        .environment(UsageManager())
        .environment(UpdateChecker())
}
