import SwiftUI
import AppKit

/// The menu bar icon that shows in the macOS status bar.
struct MenuBarIcon: View {
    let usageManager: UsageManager

    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            icon

            if let text = usageManager.menuBarDisplayText {
                Text(text)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let kind = ProviderKind(rawValue: usageManager.iconTrackProvider),
           let image = ProviderTemplateIcon.image(for: kind) {
            Image(nsImage: image)
        } else {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 14, weight: .medium))
        }
    }
}

/// Loads provider SVG icons as template `NSImage`s suitable for the menu bar.
///
/// Template images are auto-tinted by AppKit to match the menu bar's light/dark
/// appearance, and accept SwiftUI `.foregroundStyle()` tinting. We cache one
/// instance per kind because `NSImage` loading from SVG isn't free.
@MainActor
private enum ProviderTemplateIcon {
    private static let size = NSSize(width: 18, height: 18)
    private static var cache: [ProviderKind: NSImage] = [:]

    static func image(for kind: ProviderKind) -> NSImage? {
        if let cached = cache[kind] { return cached }

        guard let url = AppResources.url(
            forResource: "ProviderIcon-\(kind.rawValue)",
            withExtension: "svg",
            subdirectory: "Icons"
        ), let image = NSImage(contentsOf: url) else { return nil }

        image.size = size
        image.isTemplate = true
        cache[kind] = image
        return image
    }
}
