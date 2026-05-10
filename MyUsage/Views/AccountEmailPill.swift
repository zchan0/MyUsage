import SwiftUI

/// Small mono pill that surfaces an account's email (or `Account id:xxxx`
/// fallback) in the popover card head when ≥2 accounts have been observed
/// for a provider. Two visual modes:
///
/// - active: filled sage dot + email in body color — "this is what the
///   credentials file currently points at"
/// - inactive: hollow ring dot + email muted — "I've seen this account
///   before; the data shown is from last sign-in"
///
/// Truncates with middle ellipsis when the email overflows the available
/// width — long.address+tag@some-very-long-domain.io  →  long.…@…in.io.
struct AccountEmailPill: View {
    let displayName: String
    let isActive: Bool
    let isOpaque: Bool

    var body: some View {
        HStack(spacing: 4) {
            dot
            Text(displayName)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .truncationMode(.middle)
                .lineLimit(1)
                .foregroundStyle(textColor)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(isActive ? 0.06 : 0.04))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var dot: some View {
        if isActive {
            Circle()
                .fill(Self.sageHealthy)
                .frame(width: 6, height: 6)
        } else {
            Circle()
                .strokeBorder(Color.primary.opacity(0.35), lineWidth: 1)
                .frame(width: 6, height: 6)
        }
    }

    /// Sage matched to the LimitBar's healthy fill — unifies the visual
    /// language of "this account is the active one" with "this limit is
    /// healthy".
    private static let sageHealthy = Color(hue: 145.0/360.0, saturation: 0.45, brightness: 0.55)

    private var textColor: Color {
        if isOpaque {
            return .secondary.opacity(0.6)
        }
        return isActive ? .primary.opacity(0.85) : .secondary.opacity(0.85)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 8) {
        AccountEmailPill(displayName: "user@company.com", isActive: true, isOpaque: false)
        AccountEmailPill(displayName: "me@personal.dev", isActive: false, isOpaque: false)
        AccountEmailPill(displayName: "Account id:ab12cd34", isActive: false, isOpaque: true)
        AccountEmailPill(
            displayName: "longer.email.address+tag@some-very-long-domain.io",
            isActive: true, isOpaque: false
        )
        .frame(width: 180)
    }
    .padding()
}
