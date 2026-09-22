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
        if let provider = usageManager.providers.first(where: { $0.id.rawValue == usageManager.iconTrackProvider }),
           let image = ProviderTemplateIcon.image(for: provider.source) {
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
