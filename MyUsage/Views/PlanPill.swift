import SwiftUI

/// Compact monospaced provider-plan label ("Pro", "Max", or "Plus").
struct PlanPill: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .overlay(
                Capsule().strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
            )
    }
}

#Preview {
    PlanPill(text: "Plus")
        .padding()
}
