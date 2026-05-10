import SwiftUI

/// Banner surfaced above an inactive account's cached snapshot in the
/// popover. Communicates two things at once:
///
///   1. The data shown is **not live** — these numbers are from when this
///      account was last signed in.
///   2. **How** to make it live — sign back in via the CLI, then refresh.
///
/// Compact (single line, mono date) so it doesn't compete with the bars.
struct StaleSnapshotBanner: View {
    let capturedAt: Date

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary.opacity(0.7))

            Text(StaleSnapshotBanner.formatted(capturedAt))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    /// `Snapshot from May 8` for recent dates (< 7 days), full date
    /// otherwise. Always uses the user's locale.
    static func formatted(_ date: Date, now: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        let interval = now.timeIntervalSince(date)
        if interval < 7 * 86_400 {
            formatter.setLocalizedDateFormatFromTemplate("MMMd")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("MMMdy")
        }
        return "Snapshot from \(formatter.string(from: date))"
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 8) {
        StaleSnapshotBanner(capturedAt: Date.now.addingTimeInterval(-2 * 86_400))
        StaleSnapshotBanner(capturedAt: Date.now.addingTimeInterval(-30 * 86_400))
    }
    .padding()
    .frame(width: 300)
}
