import SwiftUI
import AppKit

/// Provider icon loaded from bundled SVG, rendered as template with accent color.
struct ProviderIcon: View {
    let kind: ProviderKind
    var size: CGFloat = 20
    /// When non-nil, the SVG is recoloured to this hex string instead of
    /// the kind's `accentColorHex`. Used by `ProviderIconTile` to render
    /// a white glyph on top of the brand-color tile background.
    var fillHex: String? = nil

    var body: some View {
        if let nsImage = loadSVG() {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            fallbackIcon
        }
    }

    private func loadSVG() -> NSImage? {
        guard let url = AppResources.url(
            forResource: "ProviderIcon-\(kind.rawValue)",
            withExtension: "svg",
            subdirectory: "Icons"
        ) else { return nil }

        guard let data = try? Data(contentsOf: url),
              var svgString = String(data: data, encoding: .utf8) else { return nil }

        let target = fillHex ?? kind.accentColorHex
        svgString = svgString.replacingOccurrences(
            of: "fill=\"white\"",
            with: "fill=\"\(target)\""
        )

        guard let svgData = svgString.data(using: .utf8),
              let image = NSImage(data: svgData) else { return nil }

        image.size = NSSize(width: size, height: size)
        return image
    }

    private var fallbackIcon: some View {
        ZStack {
            Circle().fill(kind.accentColor)
            Text(kind.initial)
                .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

/// Brand-icon tile used in the popover provider card head: a 22pt rounded
/// square filled with the provider's `brandTileColor`, with the provider
/// SVG rendered in white on top. Mirrors v7 mockup's `.card-icon` element.
struct ProviderIconTile: View {
    let kind: ProviderKind
    var size: CGFloat = 22
    var glyph: CGFloat = 13

    var body: some View {
        ProviderIconTileSurface(color: kind.brandTileColor, size: size) {
            ProviderIcon(kind: kind, size: glyph, fillHex: "#FFFFFF")
        }
    }
}

/// Shared tile finish for built-in providers and gateway vendors.
struct ProviderIconTileSurface<Glyph: View>: View {
    let color: Color
    let size: CGFloat
    @ViewBuilder let glyph: () -> Glyph

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(color)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                )
                .overlay(
                    LinearGradient(
                        colors: [Color.white.opacity(0.32), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .blendMode(.plusLighter)
                    .opacity(0.6)
                )
                .shadow(color: .black.opacity(0.12), radius: 1.5, x: 0, y: 1)

            glyph()
        }
        .frame(width: size, height: size)
    }
}

extension ProviderKind {
    var initial: String {
        switch self {
        case .claude:       "C"
        case .codex:        "X"
        case .cursor:       "Cu"
        case .antigravity:  "A"
        }
    }

    var accentColorHex: String {
        switch self {
        case .claude:       "#D6845B"
        case .codex:        "#4A4A4A"
        case .cursor:       "#60A5FA"
        case .antigravity:  "#2DC7AE"
        }
    }
}

/// Loads provider SVG icons as template `NSImage`s suitable for the menu bar.
///
/// Template images are auto-tinted by AppKit to match the menu bar's light/dark
/// appearance, and accept SwiftUI `.foregroundStyle()` tinting. We cache one
/// instance per resource because `NSImage` loading from SVG isn't free.
@MainActor
enum ProviderTemplateIcon {
    private static let size = NSSize(width: 18, height: 18)
    private static var cache: [String: NSImage] = [:]

    static func image(for kind: ProviderKind) -> NSImage? {
        image(resource: "ProviderIcon-\(kind.rawValue)")
    }

    static func image(for source: ProviderSource) -> NSImage? {
        switch source {
        case .builtin(let kind): image(for: kind)
        case .gateway(let vendor): image(resource: "ProviderIcon-\(vendor.rawValue)")
        }
    }

    private static func image(resource: String) -> NSImage? {
        if let cached = cache[resource] { return cached }

        guard let url = AppResources.url(
            forResource: resource,
            withExtension: "svg",
            subdirectory: "Icons"
        ), let image = NSImage(contentsOf: url) else { return nil }

        image.size = size
        image.isTemplate = true
        cache[resource] = image
        return image
    }
}
