import SwiftUI

/// Settings panel section card. Mirrors the popover's per-provider glass
/// card chrome (rounded 11pt, neutral glass, hairline border, soft shadow)
/// with an optional small-caps title above the content.
///
/// Use one card per logical section in a tab (Refresh, Menu Bar, Sync, …).
struct SettingsCard<Content: View>: View {
    let title: String?
    let content: () -> Content

    init(_ title: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .default))
                    .tracking(0.6)
                    .foregroundStyle(.secondary.opacity(0.7))
                    .padding(.leading, 2)
            }

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(.background.opacity(0.62))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .shadow(color: .black.opacity(0.04), radius: 1.5, x: 0, y: 1)
        }
    }
}

/// One row inside a `SettingsCard`. Label on the left, control on the right,
/// optional second-line caption below the label. Hairline divider is drawn
/// automatically between sibling rows in the same card.
struct SettingsRow<Trailing: View>: View {
    let label: String
    var caption: String? = nil
    let trailing: () -> Trailing

    init(
        _ label: String,
        caption: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.label = label
        self.caption = caption
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 12.5, weight: .medium))
                if let caption {
                    Text(caption)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary.opacity(0.75))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.vertical, 8)
    }
}

/// Hairline divider matching the popover's intra-card separator. Use between
/// sibling SettingsRows in the same card.
struct CardDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: 0.5)
    }
}
