import SwiftUI
import AppKit

/// Provider icon loaded from bundled SVG, rendered as template with accent color.
struct ProviderIcon: View {
    let kind: ProviderKind
    var size: CGFloat = 20

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
        guard let url = Bundle.module.url(
            forResource: "ProviderIcon-\(kind.rawValue)",
            withExtension: "svg",
            subdirectory: "Icons"
        ) else { return nil }

        guard let data = try? Data(contentsOf: url),
              var svgString = String(data: data, encoding: .utf8) else { return nil }

        // Replace white fill with accent color hex for proper rendering
        svgString = svgString.replacingOccurrences(
            of: "fill=\"white\"",
            with: "fill=\"\(kind.accentColorHex)\""
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
