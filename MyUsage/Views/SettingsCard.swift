import SwiftUI

/// Page-level header rendered at the top of each Settings detail pane.
struct SettingsPageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    let trailing: () -> Trailing

    init(
        _ title: String,
        subtitle: String,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    init(_ title: String, subtitle: String) where Trailing == EmptyView {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 19, weight: .bold))
                    .tracking(-0.2)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.bottom, 2)
    }
}

/// macOS System Settings-style colored icon badge for sidebar navigation items.
struct SettingsSidebarBadge: View {
    let symbol: String
    let tint: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.95), tint],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5)
                }
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 20, height: 20)
    }
}

/// Modern macOS 26 grouped settings surface with continuous corners, crisp
/// hairline edge, and restrained surface lift aligned with `GlassSheet`.
struct SettingsCard<HeaderTrailing: View, Content: View>: View {
    let title: String?
    let headerTrailing: () -> HeaderTrailing
    let content: () -> Content

    @Environment(\.colorScheme) private var colorScheme

    init(
        _ title: String? = nil,
        @ViewBuilder headerTrailing: @escaping () -> HeaderTrailing,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.headerTrailing = headerTrailing
        self.content = content
    }

    init(
        _ title: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) where HeaderTrailing == EmptyView {
        self.init(title, headerTrailing: { EmptyView() }, content: content)
    }

    var body: some View {
        let isDark = colorScheme == .dark
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

        VStack(alignment: .leading, spacing: 7) {
            if title != nil || HeaderTrailing.self != EmptyView.self {
                HStack(alignment: .firstTextBaseline) {
                    if let title {
                        Text(title)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    headerTrailing()
                }
                .padding(.horizontal, 4)
            }

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background {
                shape
                    .fill(
                        LinearGradient(
                            colors: isDark
                                ? [Color.white.opacity(0.072), Color.white.opacity(0.048)]
                                : [Color.white.opacity(0.84), Color.white.opacity(0.72)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .shadow(color: .black.opacity(isDark ? 0.18 : 0.035), radius: isDark ? 5 : 3, y: 1.5)
            }
            .overlay {
                shape
                    .strokeBorder(
                        (isDark ? Color.white : Color.black).opacity(isDark ? 0.10 : 0.07),
                        lineWidth: 0.5
                    )
                    .allowsHitTesting(false)
            }
            .clipShape(shape)
        }
    }
}

/// One row inside a `SettingsCard`. Label + optional caption on the left,
/// control on the right.
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
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2.5) {
                Text(label)
                    .font(.system(size: 12.5, weight: .medium))
                if let caption {
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.vertical, 9)
    }
}

/// Hairline divider between sibling rows in a `SettingsCard`.
struct CardDivider: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill((colorScheme == .dark ? Color.white : Color.black).opacity(colorScheme == .dark ? 0.08 : 0.065))
            .frame(height: 0.5)
    }
}
