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
///
/// Each provider glyph carries a 2pt micro-bar underneath: that
/// provider's worst window (`worstUsagePercent`), severity-tinted. The
/// CodexBar trick — every provider's pressure is scannable without
/// switching tabs.
struct ProviderTabBar: View {
    /// One provider segment: the brand tile + its micro-bar reading.
    struct Item: Identifiable {
        let kind: ProviderKind
        /// Worst-window percent (0–100); nil = no snapshot yet, which
        /// renders an empty track rather than a fake 0% reading.
        let worstPercent: Double?
        var id: ProviderKind { kind }
    }

    let items: [Item]
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

            ForEach(items) { item in
                segment(tab: .provider(item.kind)) {
                    VStack(spacing: 3) {
                        // Full-colour brand tile — identity stays crisp; the
                        // unselected state recedes via opacity alone.
                        ProviderIconTile(kind: item.kind, size: 16, glyph: 9.5)
                            .opacity(selection == .provider(item.kind) ? 1.0 : 0.72)
                        MicroUsageBar(percent: item.worstPercent)
                    }
                }
                .help(item.kind.displayName)
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
                .frame(height: 27)
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

/// The 2pt bar under a tab's brand tile. Fill = worst-window percent,
/// severity-tinted so an amber/red provider announces itself from the
/// tab strip. nil percent renders the bare track (provider not loaded).
private struct MicroUsageBar: View {
    let percent: Double?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                if let percent {
                    Capsule()
                        .fill(LimitSafety.level(for: percent).accent)
                        .frame(width: max(1.5, geo.size.width * min(percent, 100) / 100))
                }
            }
        }
        .frame(width: 16, height: 2)
    }
}

#Preview {
    struct Host: View {
        @State var selection: PopoverTab = .overview
        var body: some View {
            ProviderTabBar(
                items: [
                    .init(kind: .claude, worstPercent: 62),
                    .init(kind: .codex, worstPercent: 23),
                    .init(kind: .cursor, worstPercent: 84),
                    .init(kind: .antigravity, worstPercent: nil),
                ],
                selection: $selection
            )
            .padding(12)
            .frame(width: 340)
        }
    }
    return Host()
}
