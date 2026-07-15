import SwiftUI

/// Main popover content shown when clicking the menu bar icon.
///
/// Two-level navigation:
///   · Overview (root): one compact `OverviewRow` per enabled provider —
///     name, plan, and a terse metric summary. Tapping a row pushes the
///     provider's detail page.
///   · Detail: the full `ProviderCard` for one provider (limit bars,
///     cost row, per-model breakdown). The header's wordmark becomes a
///     back button.
///
/// Shared chrome (follows `docs/ui-mockups/popover-glassy-v7.html`):
///   · Header: wordmark / back · "X ago" (mono) · refresh
///   · Footer: settings, with a single hairline above
struct UsagePopover: View {
    @Environment(UsageManager.self) private var manager
    @Environment(UpdateChecker.self) private var updateChecker

    /// Which provider's detail page is showing; nil = Overview root.
    @State private var selectedKind: ProviderKind?

    var body: some View {
        VStack(spacing: 0) {
            header

            if let provider = selectedProvider {
                detailPage(for: provider)
            } else if enabledProviders.isEmpty {
                emptyState
            } else {
                overviewList
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
            if selectedKind != nil {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { selectedKind = nil }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Overview")
                            .font(.system(size: 12.5, weight: .semibold))
                            .tracking(-0.2)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            } else {
                Text("MyUsage")
                    .font(.system(size: 13.5, weight: .semibold))
                    .tracking(-0.2)
            }

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

    // MARK: - Pages

    /// Root page: compact rows, one per enabled provider.
    ///
    /// Plain VStack — NO ScrollView. The popover panel sizes itself to
    /// this content's intrinsic height, so a ScrollView would have no
    /// height to fill and collapse to zero. There are only ever a
    /// handful of providers, so scrolling buys nothing.
    private var overviewList: some View {
        VStack(spacing: 6) {
            ForEach(enabledProviders, id: \.kind) { provider in
                OverviewRow(provider: provider) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selectedKind = provider.kind
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 12)
    }

    /// Detail page: the full card for one provider. The card keeps its
    /// own head (icon + name + plan) so the page needs no extra title.
    private func detailPage(for provider: any UsageProvider) -> some View {
        VStack(spacing: 7) {
            ProviderCard(provider: provider)
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 12)
    }

    // MARK: - Helpers

    private var enabledProviders: [any UsageProvider] {
        manager.orderedProviders.filter { $0.isEnabled }
    }

    /// Resolves the pushed detail page's provider. Returns nil — sending
    /// the UI back to the Overview — when the provider was disabled while
    /// its detail page was showing (e.g. toggled off in Settings).
    private var selectedProvider: (any UsageProvider)? {
        guard let selectedKind else { return nil }
        return enabledProviders.first { $0.kind == selectedKind }
    }
}

#Preview {
    UsagePopover()
        .environment(UsageManager())
        .environment(UpdateChecker())
}
