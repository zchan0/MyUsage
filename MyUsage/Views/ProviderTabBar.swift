import SwiftUI

/// Which page the popover is showing.
enum PopoverTab: Equatable {
    case overview
    case provider(ProviderKind)
}

/// Flat icon rail under the popover header. Selection is communicated by a
/// bottom rule rather than another rounded container, leaving the data page as
/// the only visual surface.
struct ProviderTabBar: View {
    struct Item: Identifiable {
        let kind: ProviderKind
        var id: ProviderKind { kind }
    }

    let items: [Item]
    @Binding var selection: PopoverTab

    var body: some View {
        HStack(spacing: 0) {
            segment(tab: .overview) {
                Text("Overview")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(
                        selection == .overview ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
                    )
            }

            ForEach(items) { item in
                let selected = selection == .provider(item.kind)
                segment(tab: .provider(item.kind)) {
                    HStack(spacing: 4) {
                        ProviderIconTile(kind: item.kind, size: 16, glyph: 9.5)
                            .opacity(selected ? 1.0 : 0.78)
                        Text(item.kind == .antigravity ? "AG" : item.kind.shortName)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                }
                .help(item.kind.displayName)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
        }
    }

    private func segment(tab: PopoverTab, @ViewBuilder content: () -> some View) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { selection = tab }
        } label: {
            content()
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .overlay(alignment: .bottom) {
                    if selection == tab {
                        Capsule()
                            .fill(Color.primary.opacity(0.86))
                            .frame(maxWidth: 44)
                            .frame(height: 2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    struct Host: View {
        @State var selection: PopoverTab = .overview
        var body: some View {
            ProviderTabBar(
                items: [
                    .init(kind: .claude),
                    .init(kind: .codex),
                    .init(kind: .cursor),
                    .init(kind: .antigravity),
                ],
                selection: $selection
            )
            .padding(12)
            .frame(width: PopoverLayout.width)
        }
    }
    return Host()
}
