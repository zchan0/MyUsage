import SwiftUI

/// Full Codex reset-credit inventory for the provider detail page.
struct ResetCreditsSection: View {
    let inventory: ResetCreditInventory

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if inventory.reportedAvailableCount == 0 {
                Text("No reset credits available")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary.opacity(0.75))
                    .padding(.top, 10)
            } else if inventory.availableCredits.isEmpty {
                Text("Expiry details were not reported")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary.opacity(0.75))
                    .padding(.top, 10)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(inventory.availableCredits.enumerated()), id: \.element.id) { index, credit in
                        creditRow(index: index, credit: credit)
                    }
                }
                .padding(.top, 12)
            }

            let undisclosed = inventory.reportedAvailableCount - inventory.availableCredits.count
            if undisclosed > 0 {
                Text("\(undisclosed) additional credit\(undisclosed == 1 ? "" : "s") without expiry details")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 7)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Codex reset credits")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text("RESET CREDITS")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary.opacity(0.72))

            Text("\(inventory.reportedAvailableCount)")
                .font(.system(size: 21, weight: .semibold, design: .monospaced))
                .monospacedDigit()

            Spacer(minLength: 8)

            if let expiration = inventory.earliestExpiration {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("NEXT EXPIRY")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text("in \(OverviewSummary.shortCountdown(until: expiration))")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(expiryColor(expiration))
                }
            }
        }
    }

    private func creditRow(index: Int, credit: ResetCredit) -> some View {
        HStack(spacing: 9) {
            Text("\(index + 1)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 21, height: 21)
                .background(Color.primary.opacity(0.06), in: Circle())

            Text("Rate-limit reset")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            if let expiresAt = credit.expiresAt {
                Text(expiresAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(expiryColor(expiresAt))
            } else {
                Text("No expiry reported")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(minHeight: 42)
        .overlay(alignment: .top) {
            if index > 0 {
                Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.5)
            }
        }
    }

    private func expiryColor(_ date: Date) -> Color {
        date.timeIntervalSinceNow < 7 * 86_400 ? LimitBar.warnAccent : .primary.opacity(0.88)
    }
}

/// Compact inventory signal embedded in the Focus Overview.
struct ResetCreditsInlineSummary: View {
    let inventory: ResetCreditInventory

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "arrow.counterclockwise.circle")
                .font(.system(size: 10))
            Text("Reset credits")
                .font(.system(size: 10, weight: .medium))
            Text("\(inventory.reportedAvailableCount)")
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            if let expiration = inventory.earliestExpiration {
                Text("next expires in \(OverviewSummary.shortCountdown(until: expiration))")
                    .font(.system(size: 8.5, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.secondary.opacity(0.72))
            }
        }
        .foregroundStyle(Color.accentColor)
    }
}

#Preview("Reset credits") {
    ResetCreditsSection(
        inventory: ResetCreditInventory(
            reportedAvailableCount: 3,
            availableCredits: [
                ResetCredit(id: "a", grantedAt: nil, expiresAt: .now.addingTimeInterval(3 * 86_400)),
                ResetCredit(id: "b", grantedAt: nil, expiresAt: .now.addingTimeInterval(12 * 86_400)),
                ResetCredit(id: "c", grantedAt: nil, expiresAt: nil),
            ],
            fetchedAt: .now
        )
    )
    .padding(18)
    .frame(width: 400)
}
