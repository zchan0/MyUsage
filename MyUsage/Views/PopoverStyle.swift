import SwiftUI

enum PopoverLayout {
    static let width: CGFloat = 356
}

enum PopoverMotion {
    static let selection = Animation.spring(duration: 0.28, bounce: 0.08)
    static let meter = Animation.spring(duration: 0.42, bounce: 0.0)
    static let hover = Animation.easeOut(duration: 0.12)
    static let continuousDuration: TimeInterval = 0.85
}

/// Deterministic timeline-driven spinner that avoids SwiftUI's `repeatForever`
/// CoreAnimation stacking and stop-failure bugs on macOS.
struct SpinningRefreshGlyph: View {
    let symbol: String
    let font: Font
    let spinning: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt: Date?

    private var active: Bool { spinning && !reduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !active)) { context in
            let angle: Double = if active, let startedAt {
                max(0, context.date.timeIntervalSince(startedAt) / PopoverMotion.continuousDuration)
                    .truncatingRemainder(dividingBy: 1.0) * 360.0
            } else {
                0
            }
            Image(systemName: symbol)
                .font(font)
                .rotationEffect(.degrees(angle))
                .transaction { $0.animation = nil }
        }
        .onChange(of: active, initial: true) { _, isActive in
            startedAt = isActive ? .now : nil
        }
    }
}

enum PopoverPalette {
    case light, dark

    init(_ scheme: ColorScheme) {
        self = scheme == .dark ? .dark : .light
    }

    private var isDark: Bool { self == .dark }

    // AppKit's popover material already tints the backdrop. These are the
    // additional tint and highlights applied above that material.
    var chassisTint: Color { tone(0xEC_EDEF, 0x1A_1C21).opacity(isDark ? 0.80 : 0.68) }
    var chassisSpecular: Color { Color.white.opacity(isDark ? 0.08 : 0.86) }

    var wellBackground: Color { isDark ? .black.opacity(0.28) : Self.rgb(0x0F_121A).opacity(0.046) }
    var wellBorder: LinearGradient {
        gradient([
            (isDark ? Color.black : Self.rgb(0x0F_121A)).opacity(isDark ? 0.36 : 0.055),
            Color.white.opacity(isDark ? 0.045 : 0.72),
        ])
    }

    var lensGradient: LinearGradient {
        gradient(isDark ? [.white.opacity(0.145), .white.opacity(0.09)] : [.white, Self.rgb(0xF6_F7FA)])
    }

    var lensEdge: Color { tone(0x0F_121A, 0xFF_FFFF).opacity(isDark ? 0.13 : 0.075) }
    var lensShadow: Color { tone(0x0F_1420, 0x00_0000).opacity(isDark ? 0.32 : 0.08) }
    var lensSpecular: Color { .white.opacity(isDark ? 0.12 : 1) }
    var sheetGradient: LinearGradient {
        gradient([.white.opacity(isDark ? 0.068 : 0.90), .white.opacity(isDark ? 0.044 : 0.78)])
    }

    var sheetEdge: Color { tone(0x0F_121A, 0xFF_FFFF).opacity(isDark ? 0.078 : 0.068) }
    var sheetSpecular: Color { .white.opacity(isDark ? 0.055 : 0.95) }
    var sheetShadow: Color { tone(0x0F_1420, 0x00_0000).opacity(isDark ? 0.18 : 0.028) }

    var inkPrimary: Color { tone(0x1D_2026, 0xF0_F2F6) }
    var inkSecondary: Color { tone(0x63_6975, 0xB0_B7C4) }
    var inkTertiary: Color { tone(0x88_8F9C, 0x8A_92A2) }
    var inkQuaternary: Color { tone(0xB5_BBC6, 0x5C_6473) }

    var divider: Color { tone(0x0F_121A, 0xFF_FFFF).opacity(isDark ? 0.068 : 0.065) }
    var rowHover: Color { tone(0x0F_121A, 0xFF_FFFF).opacity(isDark ? 0.04 : 0.032) }
    var track: Color { tone(0x0F_121A, 0xFF_FFFF).opacity(isDark ? 0.095 : 0.078) }
    var paceTick: Color { tone(0x78_7F8C, 0x8C_94A3) }

    var okFill: Color { tone(0x34_A866, 0x43_BC76) }
    var okInk: Color { tone(0x24_8A50, 0x62_CF8F) }
    var warnFill: Color { tone(0xD9_822B, 0xE6_953E) }
    var warnInk: Color { tone(0xB8_6614, 0xF0_AB5D) }
    var warnPillBackground: Color { warnFill.opacity(isDark ? 0.15 : 0.12) }
    var critFill: Color { tone(0xDC_4C46, 0xEB_635D) }
    var critInk: Color { tone(0xBF_3630, 0xF4_817C) }
    var critPillBackground: Color { critFill.opacity(isDark ? 0.15 : 0.12) }

    var sparkIdle: Color { inkPrimary.opacity(isDark ? 0.21 : 0.16) }
    var sparkEmpty: Color { inkPrimary.opacity(isDark ? 0.055 : 0.05) }
    var sparkFocus: Color { tone(0x2C_313B, 0xF2_F4F8) }
    var sparkToday: Color { okFill }

    func brandHex(for kind: ProviderKind) -> String {
        switch kind {
        case .claude: isDark ? "#DF835B" : "#CF6D44"
        case .codex: isDark ? "#56BF9F" : "#2A9475"
        case .antigravity: isDark ? "#7B98F5" : "#4C70E0"
        case .cursor: isDark ? "#A5ADBD" : "#3C424F"
        }
    }

    private func tone(_ light: UInt32, _ dark: UInt32) -> Color {
        Self.rgb(isDark ? dark : light)
    }

    private static func rgb(_ hex: UInt32) -> Color {
        Color(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    private func gradient(_ colors: [Color]) -> LinearGradient {
        LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }
}

struct PopoverGlassSurface: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = PopoverPalette(colorScheme)
        palette.chassisTint
            .overlay(alignment: .top) {
                LinearGradient(
                    stops: [
                        .init(color: palette.chassisSpecular, location: 0),
                        .init(color: palette.chassisSpecular.opacity(0.22), location: 0.015),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 42)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct GlassSheet<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder let content: () -> Content

    var body: some View {
        let palette = PopoverPalette(colorScheme)
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(shape)
            .background {
                shape.fill(palette.sheetGradient)
                    .shadow(color: palette.sheetShadow, radius: colorScheme == .dark ? 5 : 4, y: 2)
            }
            .overlay {
                shape.strokeBorder(palette.sheetEdge, lineWidth: 0.5)
                    .overlay { topSpecular(shape, color: palette.sheetSpecular, inset: 0.5) }
                    .allowsHitTesting(false)
            }
    }
}

struct PopoverWell<Surface: InsettableShape>: View {
    let shape: Surface
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = PopoverPalette(colorScheme)
        shape.fill(palette.wellBackground)
            .overlay { shape.strokeBorder(palette.wellBorder, lineWidth: 0.5) }
    }
}

struct PopoverLens<Surface: InsettableShape>: View {
    let shape: Surface
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = PopoverPalette(colorScheme)
        shape.fill(palette.lensGradient)
            .overlay {
                shape.strokeBorder(palette.lensEdge, lineWidth: 0.5)
                    .overlay { topSpecular(shape, color: palette.lensSpecular, inset: 0.5) }
            }
            .shadow(color: palette.lensShadow, radius: 4, y: 2)
            .allowsHitTesting(false)
    }
}

private func topSpecular(
    _ shape: some InsettableShape, color: Color, inset: CGFloat
) -> some View {
    shape.inset(by: inset)
        .strokeBorder(
            LinearGradient(
                stops: [.init(color: color, location: 0), .init(color: .clear, location: 0.35)],
                startPoint: .top,
                endPoint: .bottom
            ),
            lineWidth: 0.5
        )
}

struct PopoverHairline: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle().fill(PopoverPalette(colorScheme).divider).frame(height: 0.5)
    }
}
