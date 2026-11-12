import SwiftUI

struct ProviderTabBar: View {
    struct Item: Identifiable {
        let id: ProviderID
        let source: ProviderSource
        let name: String
        let needsAttention: Bool

        @MainActor
        init(provider: any UsageProvider, needsAttention: Bool) {
            self.init(id: provider.id, source: provider.source, name: provider.shortName, needsAttention: needsAttention)
        }

        init(id: ProviderID, source: ProviderSource, name: String, needsAttention: Bool = false) {
            self.id = id
            self.source = source
            self.name = name
            self.needsAttention = needsAttention
        }
    }

    let items: [Item]
    @Binding var selection: ProviderID
    @Namespace private var dockNamespace
    @Environment(\.colorScheme) private var colorScheme
    @State private var hoveredID: ProviderID?

    var body: some View {
        Group {
            if items.count <= 4 {
                HStack(spacing: 0) {
                    ForEach(items) { slot($0, equalWidth: true) }
                }
            } else {
                overflowDock
            }
        }
        .padding(4)
        .background { PopoverWell(shape: RoundedRectangle(cornerRadius: 25, style: .continuous)) }
        .padding(.horizontal, 11)
        .padding(.top, 11)
        .animation(PopoverMotion.selection, value: selection)
        .onKeyPress(keys: [.leftArrow, .rightArrow], phases: .down) { press in
            guard let index = items.firstIndex(where: { $0.id == selection }) else { return .ignored }
            let offset = press.key == .leftArrow ? -1 : 1
            select(items[(index + offset + items.count) % items.count].id)
            return .handled
        }
    }

    private var overflowDock: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(items) { item in
                            slot(item, equalWidth: false)
                                .id(item.id)
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .scrollIndicators(.hidden)
                .frame(height: 46)
                .scrollClipDisabled()
                .mask {
                    HStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 6)
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 6)
                    }
                    .padding(.vertical, -4)
                }
                .onAppear { proxy.scrollTo(selection, anchor: .center) }
                .onChange(of: selection) { _, id in
                    withAnimation(PopoverMotion.selection) { proxy.scrollTo(id, anchor: .center) }
                }
                .onChange(of: items.map(\.id)) { _, _ in
                    withAnimation(PopoverMotion.selection) { proxy.scrollTo(selection, anchor: .center) }
                }
            }

            Menu {
                ForEach(items) { item in
                    Button { select(item.id) } label: {
                        if selection == item.id {
                            Label(item.name, systemImage: "checkmark")
                        } else {
                            Text(item.name)
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(PopoverPalette(colorScheme).inkSecondary)
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("All providers")
            .help("All providers")
        }
    }

    private func slot(_ item: Item, equalWidth: Bool) -> some View {
        let palette = PopoverPalette(colorScheme)
        let selected = selection == item.id
        let hovered = hoveredID == item.id
        return Button {
            select(item.id)
        } label: {
            VStack(spacing: 3.5) {
                glyph(for: item.source, palette: palette)
                    .frame(width: 16, height: 16)
                    .opacity(selected ? 1 : 0.72)
                    .offset(y: selected ? -0.5 : 0)
                    .overlay(alignment: .topTrailing) {
                        Circle()
                            .fill(palette.warnFill)
                            .frame(width: 5, height: 5)
                            .offset(x: 5, y: -1)
                            .opacity(!selected && item.needsAttention ? 1 : 0)
                            .animation(PopoverMotion.selection, value: item.needsAttention)
                    }
                    .accessibilityHidden(true)

                Text(item.name)
                    .font(.system(size: 10.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected || hovered ? palette.inkPrimary : palette.inkSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, equalWidth ? 4 : 10)
            .frame(minWidth: equalWidth ? 0 : 64, maxWidth: equalWidth ? .infinity : 136)
            .padding(.top, 7)
            .padding(.bottom, 6)
            .background {
                if selected {
                    PopoverLens(shape: RoundedRectangle(cornerRadius: 21, style: .continuous))
                        .matchedGeometryEffect(id: "dockLens", in: dockNamespace)
                        .transition(.identity)
                } else {
                    RoundedRectangle(cornerRadius: 21, style: .continuous)
                        .fill(hovered ? palette.rowHover : .clear)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(DockButtonStyle())
        .keyboardShortcut(shortcut(for: item.id))
        .onHover { inside in
            withAnimation(PopoverMotion.hover) {
                if inside { hoveredID = item.id }
                else if hoveredID == item.id { hoveredID = nil }
            }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(item.needsAttention && !selected ? "Usage needs attention" : "")
        .help(item.name)
    }

    @ViewBuilder
    private func glyph(for source: ProviderSource, palette: PopoverPalette) -> some View {
        switch source {
        case .builtin(let kind):
            ProviderIcon(kind: kind, size: 16, fillHex: palette.brandHex(for: kind))
        case .gateway:
            if let image = ProviderTemplateIcon.image(for: source) {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .foregroundStyle(source.usageTint(for: colorScheme))
            }
        }
    }

    private func select(_ id: ProviderID) {
        withAnimation(PopoverMotion.selection) { selection = id }
    }

    private func shortcut(for id: ProviderID) -> KeyboardShortcut? {
        guard let index = items.prefix(4).firstIndex(where: { $0.id == id }) else { return nil }
        return KeyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [])
    }
}

private struct DockButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(PopoverMotion.hover, value: configuration.isPressed)
    }
}

#if DEBUG
#Preview("Capsule dock · Overflow") {
    let manager = PreviewFixtures.manager(providerCount: 4, gateway: .full, gatewayCount: 3)
    UsagePopover(manager: manager, previewSelection: .builtin(.codex))
        .environment(manager)
        .environment(UpdateChecker())
}
#endif
