import SwiftUI

/// Which page the popover is showing.
enum PopoverTab: Equatable {
    case overview
    case provider(ProviderID)
}

/// Overview remains fixed while provider instances scroll at their natural width.
/// The overflow menu gives a direct route to every instance, even in a long list.
struct ProviderTabBar: View {
    struct Item: Identifiable {
        let id: ProviderID
        let source: ProviderSource
        let name: String
        @MainActor init(provider: any UsageProvider) { id = provider.id; source = provider.source; name = provider.shortName }
        init(kind: ProviderKind) { id = .builtin(kind); source = .builtin(kind); name = kind.shortName }
        init(id: ProviderID, source: ProviderSource, name: String) {
            self.id = id; self.source = source; self.name = name
        }
    }

    let items: [Item]
    @Binding var selection: PopoverTab
    @State private var railWidth: CGFloat = PopoverLayout.width
    @State private var contentWidth: CGFloat = 0
    private let overviewWidth: CGFloat = 80
    private var overflows: Bool { contentWidth > railWidth - overviewWidth + 1 }

    var body: some View {
        HStack(spacing: 0) {
            segment(tab: .overview) {
                Text("Overview")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(selection == .overview ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            }
            .frame(width: overviewWidth)

            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(items) { item in
                            let selected = selection == .provider(item.id)
                            segment(tab: .provider(item.id)) {
                                HStack(spacing: 4) {
                                    ProviderInstanceIcon(source: item.source, size: 16, glyph: 9.5)
                                        .opacity(selected ? 1 : 0.78)
                                    Text(item.source == .builtin(.antigravity) ? "AG" : item.name)
                                        .font(.system(size: 9.5, weight: .semibold))
                                        .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 10)
                                .frame(minWidth: 58, maxWidth: 136)
                                .fixedSize(horizontal: true, vertical: false)
                            }
                            .id(item.id)
                            .help(item.name)
                        }
                    }
                    .onSizeChange { contentWidth = $0.width }
                }
                .scrollIndicators(.hidden)
                .mask {
                    if overflows {
                        HStack(spacing: 0) {
                            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 6)
                            Rectangle()
                            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 6)
                        }
                    } else { Rectangle() }
                }
                .onAppear { revealSelection(proxy) }
                .onChange(of: selection) { _, _ in revealSelection(proxy) }
                .onChange(of: items.map(\.id)) { _, _ in revealSelection(proxy) }
                .onChange(of: overflows) { _, _ in revealSelection(proxy) }
            }
            .frame(height: 46)

            if overflows {
                Menu {
                    ForEach(items) { item in
                        Button { selection = .provider(item.id) } label: {
                            if selection == .provider(item.id) { Label(item.name, systemImage: "checkmark") }
                            else { Text(item.name) }
                        }
                    }
                } label: {
                    Image(systemName: "list.bullet")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).controlSize(.mini)
                .frame(width: 28, height: 46)
                .accessibilityLabel("All providers (\(items.count))")
                .help("All providers (\(items.count))")
            }
        }
        .frame(height: 46)
        .onSizeChange { railWidth = $0.width }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
        }
    }

    private func revealSelection(_ proxy: ScrollViewProxy) {
        guard case .provider(let id) = selection else { return }
        withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
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
                        Capsule().fill(Color.primary.opacity(0.86)).frame(maxWidth: 44).frame(height: 2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == tab ? .isSelected : [])
    }
}

#if DEBUG
private struct ProviderRailPreview: View {
    let count: Int
    @State private var selection = PopoverTab.overview
    var body: some View {
        ProviderTabBar(items: (0..<count).map { index in
            if index < ProviderKind.allCases.count { return .init(kind: ProviderKind.allCases[index]) }
            return .init(id: .init(rawValue: "preview:\(index)"), source: .gateway(.litellm), name: "Company gateway \(index - 3)")
        }, selection: $selection)
        .frame(width: PopoverLayout.width)
    }
}
#Preview("Provider rail · 2") { ProviderRailPreview(count: 2) }
#Preview("Provider rail · 6") { ProviderRailPreview(count: 6) }
#Preview("Provider rail · 30") { ProviderRailPreview(count: 30) }
#endif
