import AppKit
import SwiftUI

enum PopoverLayout {
    static let width: CGFloat = 356
    static let outerCornerRadius: CGFloat = 26
    static let sheetCornerRadius: CGFloat = 16
    static let horizontalPadding: CGFloat = 10
    static let menuBarGap: CGFloat = 6
}

enum PopoverMotion {
    static let selection = Animation.snappy(duration: 0.20, extraBounce: 0.0)
    static let meter = Animation.easeOut(duration: 0.26)
    static let hover = Animation.easeOut(duration: 0.12)
    static let numeric = Animation.easeOut(duration: 0.16)
    static let disclosure = Animation.snappy(duration: 0.22, extraBounce: 0.0)
    static let continuousDuration: TimeInterval = 0.85
}

@MainActor
enum SettingsWindowActivator {
    static func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            NSApp.activate(ignoringOtherApps: true)
            let settings = NSApp.windows.first {
                $0.identifier?.rawValue.contains("Settings") == true
                    || $0.frameAutosaveName.contains("Settings")
            }
            settings?.makeKeyAndOrderFront(nil)
            settings?.orderFrontRegardless()
        }
    }
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

    // Subtle readability veil over macOS 26's native NSGlassEffectView shell.
    var chassisVeil: Color { isDark ? Color.black.opacity(0.14) : Color.white.opacity(0.08) }
    var chassisSpecular: Color { Color.white.opacity(isDark ? 0.11 : 0.52) }

    var wellBackground: Color { isDark ? .black.opacity(0.24) : Self.rgb(0x0F_121A).opacity(0.055) }
    var wellBorder: LinearGradient {
        gradient([
            (isDark ? Color.black : Self.rgb(0x0F_121A)).opacity(isDark ? 0.34 : 0.06),
            Color.white.opacity(isDark ? 0.08 : 0.58),
        ])
    }

    var lensGradient: LinearGradient {
        gradient(isDark ? [.white.opacity(0.17), .white.opacity(0.10)] : [.white.opacity(0.92), Self.rgb(0xF6_F7FA).opacity(0.84)])
    }
    var lensEdge: Color { tone(0x0F_121A, 0xFF_FFFF).opacity(isDark ? 0.16 : 0.08) }
    var lensShadow: Color { tone(0x0F_1420, 0x00_0000).opacity(isDark ? 0.34 : 0.09) }
    var lensSpecular: Color { .white.opacity(isDark ? 0.18 : 1.0) }

    // Crisp translucent inner data sheets (intentionally non-glass to avoid muddy glass-on-glass).
    var sheetGradient: LinearGradient {
        gradient([
            .white.opacity(isDark ? 0.088 : 0.74),
            .white.opacity(isDark ? 0.056 : 0.62),
        ])
    }

    var sheetEdge: Color { tone(0x0F_121A, 0xFF_FFFF).opacity(isDark ? 0.11 : 0.08) }
    var sheetSpecular: Color { .white.opacity(isDark ? 0.10 : 0.90) }
    var sheetShadow: Color { tone(0x0F_1420, 0x00_0000).opacity(isDark ? 0.22 : 0.04) }

    var inkPrimary: Color { tone(0x16_1920, 0xF3_F5F9) }
    var inkSecondary: Color { tone(0x56_5D6B, 0xB4_BCCB) }
    var inkTertiary: Color { tone(0x7B_8392, 0x8D_96A8) }
    var inkQuaternary: Color { tone(0xAE_B5C2, 0x5E_6778) }

    var divider: Color { tone(0x0F_121A, 0xFF_FFFF).opacity(isDark ? 0.08 : 0.07) }
    var rowHover: Color { tone(0x0F_121A, 0xFF_FFFF).opacity(isDark ? 0.055 : 0.045) }
    var track: Color { tone(0x0F_121A, 0xFF_FFFF).opacity(isDark ? 0.11 : 0.085) }
    var paceTick: Color { tone(0x70_7888, 0x94_9DAE) }

    var okFill: Color { tone(0x30_A664, 0x45_C279) }
    var okInk: Color { tone(0x1E_844C, 0x64_D392) }
    var warnFill: Color { tone(0xD9_822B, 0xEB_9842) }
    var warnInk: Color { tone(0xB3_6110, 0xF3_B062) }
    var warnPillBackground: Color { warnFill.opacity(isDark ? 0.17 : 0.13) }
    var critFill: Color { tone(0xDC_4C46, 0xEE_6660) }
    var critInk: Color { tone(0xBA_322C, 0xF7_8681) }
    var critPillBackground: Color { critFill.opacity(isDark ? 0.17 : 0.13) }
    var neutralPillBackground: Color { tone(0x0F_121A, 0xFF_FFFF).opacity(isDark ? 0.10 : 0.06) }
    var neutralPillEdge: Color { tone(0x0F_121A, 0xFF_FFFF).opacity(isDark ? 0.14 : 0.09) }

    var sparkIdle: Color { inkPrimary.opacity(isDark ? 0.22 : 0.17) }
    var sparkEmpty: Color { inkPrimary.opacity(isDark ? 0.06 : 0.055) }
    var sparkFocus: Color { tone(0x22_2832, 0xF5_F7FA) }
    var sparkToday: Color { okFill }

    func brandHex(for kind: ProviderKind) -> String {
        switch kind {
        case .claude: isDark ? "#E58B63" : "#CF6D44"
        case .codex: isDark ? "#5AC7A6" : "#2A9475"
        case .antigravity: isDark ? "#84A0F8" : "#4C70E0"
        case .cursor: isDark ? "#B0B8C8" : "#3C424F"
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

/// Light atmospheric veil layered gently over `NSGlassEffectView` so native
/// Liquid Glass refraction remains visible while ink stays high-contrast.
struct PopoverGlassSurface: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = PopoverPalette(colorScheme)
        palette.chassisVeil
            .overlay(alignment: .top) {
                LinearGradient(
                    stops: [
                        .init(color: palette.chassisSpecular, location: 0),
                        .init(color: palette.chassisSpecular.opacity(0.18), location: 0.025),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 36)
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
        let shape = RoundedRectangle(cornerRadius: PopoverLayout.sheetCornerRadius, style: .continuous)
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(shape)
            .background {
                shape.fill(palette.sheetGradient)
                    .shadow(color: palette.sheetShadow, radius: colorScheme == .dark ? 6 : 4, y: 2)
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

/// Crisp elevated lens fill layered inside a SwiftUI `.glassEffect` container
/// so active capsules keep unmistakable figure-ground contrast on any backdrop.
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
