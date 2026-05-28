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
                // Plain VStack — NO ScrollView. Inside a MenuBarExtra(.window),
                // which sizes the window to its content's intrinsic height, a
                // ScrollView has no height to fill so it collapses to zero and
                // the cards vanish (header + footer still show because they
                // live outside it). This regressed with the macOS 26 update,
                // which changed how MenuBarExtra measures its content. A plain
                // VStack sizes to its cards and renders reliably; there are
                // only ever a handful of provider cards, so scrolling buys
                // nothing.
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
        // Pin the popover to its content's exact height. Inside a
        // MenuBarExtra(.window) the window grows to fit the tallest layout
        // it has shown (e.g. an account-switcher card) but is reluctant to
        // shrink again — leaving a transparent strip below the footer when
        // a shorter layout is shown. fixedSize tells SwiftUI to take the
        // content's ideal height and refuse a taller proposal, so the
        // window tracks the real content height with no leftover gap.
        .fixedSize(horizontal: false, vertical: true)
        // Own the popover chrome (rounded material background + clear
        // window) so the corners stay rounded at any height. The system
        // panel's corner mask doesn't follow a tall fixedSize resize on
        // macOS 26, exposing a white corner notch in dark mode; drawing
        // our own rounded material that tracks the content size fixes it.
        // Single rounding source: the material layer rounds itself and
        // snaps to live resizes (RoundedMaterialView disables implicit
        // animation). A SwiftUI .clipShape on top would be a second,
        // separately-timed mask that can lag the resize and re-expose the
        // transparent corner — so we deliberately don't add one. Content
        // is inset from the edges (header/footer/card padding), so it
        // never pokes into the rounded corners.
        .background(PopoverMaterialBackground(cornerRadius: 12))
        .background(PopoverWindowConfigurator())
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

    /// Single-account providers render the original `ProviderCard`
    /// directly (today's UX preserved verbatim). Multi-account providers
    /// (≥ 2 observed) render the swipeable `ProviderSwitcherCard`. The
    /// branch is per-provider so signing into a second Claude account
    /// only affects Claude's card, not the others.
    @ViewBuilder
    private func providerSlot(for provider: any UsageProvider) -> some View {
        let accounts = manager.accountStore.accounts(for: provider.kind)
        if accounts.count >= 2 {
            ProviderSwitcherCard(provider: provider, accounts: accounts)
        } else {
            ProviderCard(provider: provider)
        }
    }
}

#Preview {
    UsagePopover()
        .environment(UsageManager())
        .environment(UpdateChecker())
}
