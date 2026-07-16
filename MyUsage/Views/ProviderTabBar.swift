import SwiftUI

/// Which page the popover is showing.
enum PopoverTab: Equatable {
    case overview
    case provider(ProviderKind)
}

/// Segmented tab strip under the popover header: `Overview` plus one
/// icon tab per enabled provider. Native-segmented-control look — a
/// recessed track with an elevated pill under the selected segment —
/// but with the provider brand tiles as the tab glyphs, which is where
/// the popover gets its colour.
struct ProviderTabBar: View {
    let providers: [ProviderKind]
    @Binding var selection: PopoverTab

    var body: some View {
        HStack(spacing: 2) {
            segment(tab: .overview) {
                Text("Overview")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(
                        selection == .overview ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
                    )
            }

            ForEach(providers, id: \.self) { kind in
                segment(tab: .provider(kind)) {
                    // Full-colour brand tile — identity stays crisp; the
                    // unselected state recedes via opacity alone.
                    ProviderIconTile(kind: kind, size: 18, glyph: 11)
                        .opacity(selection == .provider(kind) ? 1.0 : 0.72)
                }
                .help(kind.displayName)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func segment(tab: PopoverTab, @ViewBuilder content: () -> some View) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { selection = tab }
        } label: {
            content()
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .background {
                    if selection == tab {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.background)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                            )
                            .shadow(color: .black.opacity(0.08), radius: 1, x: 0, y: 0.5)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    struct Host: View {
        @State var selection: PopoverTab = .overview
        var body: some View {
            ProviderTabBar(
                providers: [.claude, .codex, .cursor, .antigravity],
                selection: $selection
            )
            .padding(12)
            .frame(width: 340)
        }
    }
    return Host()
}
