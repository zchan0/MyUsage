import SwiftUI

struct ProviderDeck: View {
    let provider: any UsageProvider
    var body: some View {
        if let builtin = provider as? any BuiltinUsageProvider {
            BuiltinProviderDeck(provider: builtin)
        } else if let gateway = provider as? GatewayProvider {
            GatewayProviderDeck(provider: gateway)
        }
    }
}

struct ProviderInstanceIcon: View {
    let source: ProviderSource
    var size: CGFloat = 24
    var glyph: CGFloat = 14
    var body: some View {
        switch source {
        case .builtin(let kind): ProviderIconTile(kind: kind, size: size, glyph: glyph)
        case .gateway(let vendor):
            ProviderIconTileSurface(color: vendor.brandTileColor, size: size) {
                if let image = ProviderTemplateIcon.image(for: source) {
                    Image(nsImage: image)
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                        .foregroundStyle(.white)
                        .frame(width: glyph, height: glyph)
                }
            }.accessibilityLabel(source.displayName)
        }
    }
}

extension GatewayVendor {
    var brandTileColor: Color {
        switch self {
        case .litellm: Color(red: 0.22, green: 0.52, blue: 0.61)
        }
    }
}

/// The page scrolls when necessary; the surrounding navigation and footer stay visible.
struct PopoverPage<Content: View>: View {
    @State private var contentHeight: CGFloat = 1
    @ViewBuilder let content: () -> Content
    var body: some View {
        ScrollView(.vertical) {
            content()
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
                .onSizeChange { contentHeight = $0.height }
        }
        .frame(height: min(contentHeight, max(180, (NSScreen.main?.visibleFrame.height ?? 800) - 130)))
    }
}

@Observable @MainActor
final class PopoverPresentation {
    var isVisible = false
}

private struct PopoverPresentationKey: EnvironmentKey {
    static let defaultValue: PopoverPresentation? = nil
}

extension EnvironmentValues {
    var popoverPresentation: PopoverPresentation? {
        get { self[PopoverPresentationKey.self] }
        set { self[PopoverPresentationKey.self] = newValue }
    }
}

#Preview("LiteLLM · menu bar and provider tiles") {
    VStack(spacing: 0) {
        ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
            HStack(spacing: 18) {
                if let image = ProviderTemplateIcon.image(for: .gateway(.litellm)) {
                    Image(nsImage: image).foregroundStyle(.primary)
                }
                ProviderInstanceIcon(source: .gateway(.litellm), size: 27, glyph: 15)
                ProviderInstanceIcon(source: .builtin(.claude), size: 27, glyph: 15)
                Text("LiteLLM").font(.system(size: 12, weight: .medium))
            }
            .padding(20)
            .background(scheme == .dark ? Color(white: 0.15) : Color(white: 0.96))
            .environment(\.colorScheme, scheme)
        }
    }
}
