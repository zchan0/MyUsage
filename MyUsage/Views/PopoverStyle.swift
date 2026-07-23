import SwiftUI

/// Shared geometry and surface treatment for both merged and per-provider
/// popovers. The AppKit panel already supplies the live backdrop blur; this
/// SwiftUI layer only neutralizes wallpaper colour bleed and adds a restrained
/// highlight so the material reads as clean glass in both appearances.
enum PopoverLayout {
    static let width: CGFloat = 348
}

struct PopoverGlassSurface: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .top) {
            // A · Clean Glass: use a neutral, substantially opaque overlay
            // instead of windowBackgroundColor. The latter carries its own
            // warm-gray cast and lets too much wallpaper colour through.
            if colorScheme == .dark {
                Color(red: 37 / 255, green: 39 / 255, blue: 44 / 255)
                    .opacity(0.90)
            } else {
                Color.white.opacity(0.86)
            }

            LinearGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.045 : 0.20),
                    Color.white.opacity(colorScheme == .dark ? 0.012 : 0.04),
                    .clear,
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 150)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

#Preview("Glass Surface") {
    VStack(alignment: .leading, spacing: 10) {
        Text("MyUsage")
            .font(.headline)
        Text("Neutral glass keeps the desktop's light without its colour cast.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
    .padding(18)
    .frame(width: PopoverLayout.width, height: 140, alignment: .topLeading)
    .background { PopoverGlassSurface() }
}
