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
                ProviderDeck(provider: provider, showsHeader: false)
            }

            PopoverFooterBar()
        }
        .frame(width: PopoverLayout.width)
        .background { PopoverGlassSurface() }
        // Content-sized panel — see UsagePopover for the sizing contract.
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(spacing: 7) {
            ProviderIconTile(kind: kind, size: 20, glyph: 12)

            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(kind.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(-0.2)

                if let plan = manager.orderedProviders
                    .first(where: { $0.kind == kind })?.snapshot?.planName {
                    PlanPill(text: plan)
                }
            }

            Spacer()

            if let lastRefreshed = manager.lastRefreshed {
                RelativeTimestampLabel(date: lastRefreshed)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 62)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
        }
    }
}

// MARK: - Shared popover chrome

/// "N min ago" mono label used in both popover headers.
struct RelativeTimestampLabel: View {
    let date: Date

    var body: some View {
        (
            Text(date, style: .relative)
                .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                .monospacedDigit()
            + Text(" ago")
                .font(.system(size: 10.5, weight: .regular, design: .monospaced))
        )
        .foregroundStyle(.secondary.opacity(0.7))
    }
}

/// Compact action rail shared by both popovers. It preserves every command
/// from the previous vertical menu without spending roughly a quarter of the
/// panel height on app chrome.
struct PopoverFooterBar: View {
    @Environment(UsageManager.self) private var manager
    @Environment(UpdateChecker.self) private var updateChecker

    var body: some View {
        HStack(spacing: 2) {
            Text("v\(AppInfo.version)")
                .font(.system(size: 8.5, design: .monospaced))
                .foregroundStyle(.tertiary)

            Spacer()

            iconButton(
                "arrow.clockwise",
                help: "Refresh",
                disabled: manager.isRefreshing
            ) {
                Task { await manager.refreshAll() }
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
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
        }
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
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(disabled)
        .help(help)
    }
}

/// One row in the bottom action menu. Renders a left-aligned icon + label
/// with an optional trailing accessory (freshness text, version, or an
/// update dot), and highlights the whole row on hover — the native
/// menu-item feel. Built as a plain button so keyboard focus and the
/// disabled state come for free.
struct FooterMenuRow: View {
    enum Tint { case normal, quit }
    enum Trailing: Equatable { case none, dot, text(String) }

    let icon: String
    let label: String
    var tint: Tint = .normal
    var trailing: Trailing = .none
    var spinning: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(icon: icon, label: label, tint: tint, trailing: trailing, spinning: spinning)
        }
        .buttonStyle(RowStyle(tint: tint))
    }

    /// The row's inner content, factored out so `SettingsLink` (which
    /// must own its own button) can reuse the exact same look.
    struct Label: View {
        let icon: String
        let label: String
        var tint: Tint = .normal
        var trailing: Trailing = .none
        var spinning: Bool = false

        var body: some View {
            HStack(spacing: 9) {
                ZStack {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .foregroundStyle(tint == .quit ? AnyShapeStyle(quitColor) : AnyShapeStyle(.secondary))
                        .rotationEffect(.degrees(spinning ? 360 : 0))
                        .animation(
                            spinning ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                            value: spinning
                        )
                }
                .frame(width: 16)

                Text(label)
                    .font(.system(size: 12.5))
                    .foregroundStyle(tint == .quit ? AnyShapeStyle(quitColor) : AnyShapeStyle(.primary.opacity(0.92)))

                Spacer(minLength: 8)

                switch trailing {
                case .none:
                    EmptyView()
                case .dot:
                    Circle()
                        .fill(Color(hue: 0.02, saturation: 0.6, brightness: 0.7))
                        .frame(width: 6, height: 6)
                case .text(let value):
                    Text(value)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }

        private var quitColor: Color {
            Color(hue: 0.02, saturation: 0.5, brightness: 0.62)
        }
    }

    /// Row-wide hover highlight. A ButtonStyle (not `.onHover` on the
    /// label) so the pressed and hovered states share one place and the
    /// highlight fills the full row width.
    struct RowStyle: ButtonStyle {
        var tint: Tint = .normal
        @State private var hovering = false

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : (hovering ? 0.07 : 0)))
                )
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

#Preview {
    ProviderPopover(kind: .claude)
        .environment(UsageManager())
        .environment(UpdateChecker())
}
