import SwiftUI

/// Panel content for one provider in separate-icons mode: header with the
/// provider's name, the full detail card (hero tiles + bars + cost +
/// chart), and the standard footer. Deliberately no Overview and no tab
/// strip — per the CodexBar model, those exist only in merged mode; a
/// provider's own menu-bar icon opens that provider and nothing else.
struct ProviderPopover: View {
    let kind: ProviderKind

    @Environment(UsageManager.self) private var manager
    @Environment(UpdateChecker.self) private var updateChecker

    var body: some View {
        VStack(spacing: 0) {
            header

            if let provider = manager.orderedProviders.first(where: { $0.kind == kind }) {
                VStack(spacing: 7) {
                    ProviderCard(provider: provider, showsHero: true)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }

            PopoverFooterBar()
        }
        .frame(width: 340)
        // Content-sized panel — see UsagePopover for the sizing contract.
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(kind.displayName)
                .font(.system(size: 13.5, weight: .semibold))
                .tracking(-0.2)

            Spacer()

            if let lastRefreshed = manager.lastRefreshed {
                RelativeTimestampLabel(date: lastRefreshed)
            }

            PopoverRefreshButton()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 9)
    }
}

// MARK: - Shared popover chrome

/// "N min ago" mono label used in both popover headers.
struct RelativeTimestampLabel: View {
    let date: Date

    var body: some View {
        (
            Text(date, style: .relative)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .monospacedDigit()
            + Text(" ago")
                .font(.system(size: 10, weight: .regular, design: .monospaced))
        )
        .foregroundStyle(.secondary.opacity(0.7))
    }
}

/// The spinning refresh button with the update-available badge, shared by
/// the merged popover header and every per-provider popover header.
struct PopoverRefreshButton: View {
    @Environment(UsageManager.self) private var manager
    @Environment(UpdateChecker.self) private var updateChecker

    var body: some View {
        Button {
            Task { await manager.refreshAll() }
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "arrow.clockwise")
                    // `.resizable().scaledToFit()` makes the symbol a pure
                    // shape that fills its frame, geometrically centered —
                    // so rotating around .center spins it in place instead
                    // of orbiting a text baseline (see UsagePopover history).
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
}

/// Hairline + settings-gear footer shared by both popover roots.
struct PopoverFooterBar: View {
    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 0.5)

            HStack {
                Spacer()

                SettingsLink {
                    Image(systemName: "gear")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded {
                    // An LSUIElement app isn't active when the click comes
                    // from a nonactivating panel, so the Settings window
                    // opens behind whatever app IS active. Activate now,
                    // then explicitly raise the Settings window once
                    // SettingsLink has created it — under macOS 14+
                    // cooperative activation the delayed activate alone
                    // isn't reliable.
                    NSApp.activate(ignoringOtherApps: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        NSApp.activate(ignoringOtherApps: true)
                        let settings = NSApp.windows.first {
                            $0.identifier?.rawValue.contains("Settings") == true
                                || $0.frameAutosaveName.contains("Settings")
                        }
                        settings?.makeKeyAndOrderFront(nil)
                        settings?.orderFrontRegardless()
                    }
                })
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }
}

#Preview {
    ProviderPopover(kind: .claude)
        .environment(UsageManager())
        .environment(UpdateChecker())
}
