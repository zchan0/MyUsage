import SwiftUI

/// A snapshot's receipt time stays independent of MyUsage's local refresh time.
struct ClaudeSnapshotTimestamp: View {
    let receivedAt: Date?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Snapshot received")

            if let receivedAt {
                Text(receivedAt, format: .dateTime.month(.twoDigits).day(.twoDigits).hour().minute().second())
                Text("·")
                (Text(receivedAt, style: .relative) + Text(" ago"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } else {
                Text("Not received")
            }
        }
        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .help(helpText)
        .accessibilityElement(children: .combine)
    }

    private var helpText: String {
        let explanation = "Local receipt time, not the server sample time. Refreshing MyUsage does not change this timestamp."
        guard let receivedAt else { return "No statusline snapshot has been received." }
        return receivedAt.formatted(date: .complete, time: .complete) + "\n" + explanation
    }
}

#Preview("Claude snapshot receipt times") {
    VStack(alignment: .leading, spacing: 16) {
        ClaudeSnapshotTimestamp(receivedAt: .now.addingTimeInterval(-120))
        ClaudeSnapshotTimestamp(receivedAt: .now.addingTimeInterval(-86400))
        ClaudeSnapshotTimestamp(receivedAt: nil)
    }
    .padding(16)
    .frame(width: 390)
}
