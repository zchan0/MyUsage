import SwiftUI

/// Full Codex reset-credit inventory for the provider detail page.
struct ResetCreditsSection: View {
    let inventory: ResetCreditInventory
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasExpiryDetails {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        isExpanded.toggle()
                    }
                } label: {
                    header
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Hide reset-credit expiries" : "Show reset-credit expiries")
            } else {
                header
            }

            if isExpanded && hasExpiryDetails {
                VStack(spacing: 0) {
                    ForEach(Array(inventory.availableCredits.enumerated()), id: \.element.id) { index, credit in
                        creditRow(index: index, credit: credit)
                    }
                }
                .padding(.top, 12)
            }

            let undisclosed = inventory.reportedAvailableCount - inventory.availableCredits.count
            if isExpanded && undisclosed > 0 {
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
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Reset credits")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)

            Text("\(inventory.reportedAvailableCount) available")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .monospacedDigit()

            Spacer(minLength: 12)

            if let expiration = inventory.earliestExpiration {
                Text("next")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(expiration, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(expiryColor(expiration))
            } else if inventory.reportedAvailableCount > 0 {
                Text("expiry not reported")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            if hasExpiryDetails {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
        }
        .frame(minHeight: 24)
        .contentShape(Rectangle())
    }

    private var hasExpiryDetails: Bool {
        !inventory.availableCredits.isEmpty
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
