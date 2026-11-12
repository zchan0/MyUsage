import SwiftUI

/// Panel content for one provider in separate-icons mode.
struct ProviderPopover: View {
    let id: ProviderID

    @Environment(UsageManager.self) private var manager

    var body: some View {
        let provider = manager.orderedProviders.first { $0.id == id }
        VStack(spacing: 0) {
            if let provider {
                PopoverPage { ProviderDeck(provider: provider) }
            }
            PopoverFooterBar(provider: provider)
        }
        .frame(width: PopoverLayout.width)
        .background { PopoverGlassSurface() }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct PopoverFooterBar: View {
    var provider: (any UsageProvider)? = nil
    @Environment(UsageManager.self) private var manager
    @Environment(UpdateChecker.self) private var updateChecker
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 2) {
            timestamp
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(PopoverPalette(colorScheme).inkTertiary)
                .help(timestampHelp)

            Spacer()

            Button {
                Task { await manager.refreshAll(trigger: .manual) }
            } label: {
                FooterIcon(symbol: "arrow.clockwise", spinning: manager.isRefreshing)
            }
            .buttonStyle(.plain)
            .disabled(manager.isRefreshing)
            .accessibilityLabel("Refresh")
            .help(manager.isRefreshing ? "Refreshing…" : "Refresh")

            settingsButton

            if let update = updateChecker.updateAvailable {
                Button {
                    NSWorkspace.shared.open(update.url)
                } label: {
                    FooterIcon(symbol: "arrow.up.circle", highlighted: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Update available")
                .help("Update available")
            }

            Menu {
                Button("About MyUsage") {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
                Divider()
                Button("Quit MyUsage") { NSApp.terminate(nil) }
            } label: {
                FooterIcon(symbol: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24, height: 24)
            .accessibilityLabel("More")
            .help("More · MyUsage v\(AppInfo.version)")
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .frame(minHeight: 36)
    }

    @ViewBuilder
    private var timestamp: some View {
        if manager.isRefreshing {
            Text("Refreshing…")
        } else if let date = displayUpdatedAt {
            HStack(spacing: 3) {
                Text("Updated")
                Text(date, style: .relative)
                Text("ago")
            }
            .accessibilityElement(children: .combine)
        } else {
            Text("Not refreshed")
        }
    }

    private var gatewaySnapshot: GatewaySnapshot? {
        guard let provider, case .gateway(let snapshot) = provider.payload else { return nil }
        return snapshot
    }

    private var displayUpdatedAt: Date? {
        if let gatewaySnapshot { return gatewaySnapshot.displayUpdatedAt }
        return manager.lastRefreshed
    }

    private var timestampHelp: String {
        if manager.isRefreshing { return "Refreshing…" }
        guard let snapshot = gatewaySnapshot else { return "Last refresh" }
        var details: [String] = []
        if snapshot.summary.value != nil, let date = snapshot.summary.updatedAt {
            details.append("Budget: " + date.formatted(date: .abbreviated, time: .standard))
        }
        if snapshot.history.value != nil, let date = snapshot.history.updatedAt {
            details.append("Monthly usage: " + date.formatted(date: .abbreviated, time: .standard))
        }
        return details.isEmpty ? "Last refresh" : details.joined(separator: "\n")
    }

    private var settingsButton: some View {
        SettingsLink {
            FooterIcon(symbol: "gearshape")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
        .help("Settings")
        .simultaneousGesture(TapGesture().onEnded {
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
}

private struct FooterIcon: View {
    let symbol: String
    var spinning = false
    var highlighted = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        let palette = PopoverPalette(colorScheme)
        let hovered = isHovered && isEnabled
        SpinningRefreshGlyph(
            symbol: symbol,
            font: .system(size: 13, weight: .medium),
            spinning: spinning
        )
        .foregroundStyle(highlighted ? palette.warnInk : hovered ? palette.inkPrimary : palette.inkSecondary)
        .frame(width: 24, height: 24)
        .background(hovered ? palette.rowHover : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(PopoverMotion.hover, value: hovered)
    }
}

#if DEBUG
#Preview("Claude · Separate icon") {
    ProviderPopover(id: .builtin(.claude))
        .environment(PreviewFixtures.manager(providerCount: 1))
        .environment(UpdateChecker())
}
#endif
