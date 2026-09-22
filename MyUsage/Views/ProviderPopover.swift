import SwiftUI

/// Panel content for one provider in separate-icons mode. The same account-
/// first Detail used by merged mode opens directly, without Overview or tabs.
struct ProviderPopover: View {
    let id: ProviderID

    @Environment(UsageManager.self) private var manager
    @Environment(UpdateChecker.self) private var updateChecker

    var body: some View {
        VStack(spacing: 0) {
            if let provider = manager.orderedProviders.first(where: { $0.id == id }) {
                PopoverPage { ProviderDeck(provider: provider) }
            }

            PopoverFooterBar(provider: manager.orderedProviders.first { $0.id == id })
        }
        .frame(width: PopoverLayout.width)
        .background { PopoverGlassSurface() }
        // Content-sized panel — see UsagePopover for the sizing contract.
        .fixedSize(horizontal: false, vertical: true)
    }

}

// MARK: - Shared popover chrome

/// "N min ago" mono label used by the compact footer. Shares the footer's
/// size / weight / colour so the "Updated" prefix and the relative time read
/// as one label rather than two mismatched fonts.
struct RelativeTimestampLabel: View {
    let date: Date

    var body: some View {
        (
            Text(date, style: .relative)
            + Text(" ago")
        )
        .font(.system(size: 10, weight: .regular, design: .monospaced))
        .monospacedDigit()
        .foregroundStyle(.tertiary)
    }
}

/// Compact action rail shared by both popovers. It preserves every command
/// from the previous vertical menu without spending roughly a quarter of the
/// panel height on app chrome.
struct PopoverFooterBar: View {
    var provider: (any UsageProvider)? = nil
    @Environment(UsageManager.self) private var manager
    @Environment(UpdateChecker.self) private var updateChecker

    var body: some View {
        HStack(spacing: 2) {
            if let lastRefreshed = displayUpdatedAt {
                HStack(spacing: 4) {
                    Text(gatewaySnapshot?.hasDisplayIssue == true ? "Data from" : "Updated")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    RelativeTimestampLabel(date: lastRefreshed)
                }.help(timestampHelp)
            } else {
                Text("Not refreshed")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            iconButton(
                "arrow.clockwise",
                help: manager.isRefreshing ? "Refreshing…" : "Refresh",
                disabled: manager.isRefreshing,
                spinning: manager.isRefreshing
            ) {
                Task { await manager.refreshAll(trigger: .manual) }
            }

            settingsButton

            if let update = updateChecker.updateAvailable {
                iconButton("arrow.up.circle", help: "Update available") {
                    NSWorkspace.shared.open(update.url)
                }
                .foregroundStyle(.orange)
            }

            Menu {
                Button("About MyUsage") {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
                Divider()
                Button("Quit MyUsage") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .help("MyUsage v\(AppInfo.version)")
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
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
        guard let snapshot = gatewaySnapshot else { return "Last refresh" }
        var details: [String] = []
        if snapshot.summary.value != nil, let date = snapshot.summary.updatedAt {
            details.append("Budget: " + date.formatted(date: .abbreviated, time: .standard))
        }
        if snapshot.history.value != nil, let date = snapshot.history.updatedAt {
            details.append("Monthly usage: " + date.formatted(date: .abbreviated, time: .standard))
        }
        return details.joined(separator: "\n")
    }

    private var settingsButton: some View {
        SettingsLink {
            Image(systemName: "gearshape")
                .font(.system(size: 12))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
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

    private func iconButton(
        _ icon: String,
        help: String,
        disabled: Bool = false,
        spinning: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(
                    spinning
                        ? .linear(duration: 1).repeatForever(autoreverses: false)
                        : .default,
                    value: spinning
                )
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(disabled)
        .help(help)
    }
}

#Preview {
    ProviderPopover(id: .builtin(.claude))
        .environment(UsageManager())
        .environment(UpdateChecker())
}
