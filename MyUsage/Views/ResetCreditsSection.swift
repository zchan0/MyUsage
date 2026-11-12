import SwiftUI

struct ResetCreditsSection: View {
    let inventory: ResetCreditInventory
    @Environment(\.colorScheme) private var colorScheme
    @State private var isExpanded = false
    @State private var isHovered = false

    private var palette: PopoverPalette { PopoverPalette(colorScheme) }
    private var hasExpiryDetails: Bool { !inventory.availableCredits.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PopoverHairline()
            if hasExpiryDetails {
                Button {
                    withAnimation(PopoverMotion.selection) { isExpanded.toggle() }
                } label: {
                    header
                        .background(isHovered ? palette.rowHover : .clear)
                }
                .buttonStyle(.plain)
                .onHover { isHovered = $0 }
                .animation(PopoverMotion.hover, value: isHovered)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                .help(isExpanded ? "Hide reset-credit details" : "Show reset-credit details")
            } else {
                header
            }

            if isExpanded && hasExpiryDetails {
                drawer
                    .transition(.opacity)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        let now = Date.now
        let nextExpiry = inventory.earliestExpiration
        let soon = nextExpiry.map { expiresSoon($0, now: now) } ?? false
        return HStack(spacing: 6) {
            Text("Reset credits")
                .fontWeight(.medium)
                .foregroundStyle(palette.inkSecondary)

            Text("\(inventory.reportedAvailableCount) available")
                .font(.system(size: 10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(palette.inkPrimary)

            Spacer(minLength: 4)

            Text(expiryCaption(nextExpiry, now: now))
                .fontWeight(soon ? .medium : .regular)
                .monospacedDigit()
                .foregroundStyle(soon ? palette.warnInk : palette.inkTertiary)
                .lineLimit(1)

            if hasExpiryDetails {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(palette.inkTertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
        }
        .font(.system(size: 10.5))
        .padding(.horizontal, 15)
        .padding(.vertical, 9.5)
        .contentShape(Rectangle())
    }

    private var drawer: some View {
        let now = Date.now
        let disclosedCount = inventory.availableCredits.reduce(0) { $0 + $1.count }
        let undisclosed = max(0, inventory.reportedAvailableCount - disclosedCount)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(inventory.availableCredits.enumerated()), id: \.element.id) { index, credit in
                VStack(spacing: 5) {
                    PopoverHairline()
                    creditRow(credit, index: index, now: now)
                }
            }

            if undisclosed > 0 {
                Text("\(undisclosed) additional credit\(undisclosed == 1 ? "" : "s") without expiry details")
                    .font(.system(size: 10))
                    .foregroundStyle(palette.inkTertiary)
            }
        }
        .padding(.horizontal, 15)
        .padding(.top, 2)
        .padding(.bottom, 11)
    }

    private func creditRow(_ credit: ResetCredit, index: Int, now: Date) -> some View {
        let label = credit.label ?? "#\(index + 1) · Rate-limit reset"
        let title = label + (credit.count > 1 ? " ×\(credit.count)" : "")
        let soon = credit.expiresAt.map { expiresSoon($0, now: now) } ?? false
        let expiry = credit.expiresAt.map {
            let day = $0.formatted(.dateTime.month(.abbreviated).day())
            let time = $0.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
            return "\(day), \(time)"
        } ?? "No expiry reported"

        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(palette.inkSecondary)
                .lineLimit(1)
                .help(title)

            Spacer(minLength: 0)

            Text(expiry)
                .font(.system(size: 10, weight: soon ? .medium : .regular))
                .monospacedDigit()
                .foregroundStyle(soon ? palette.warnInk : palette.inkSecondary)
                .fixedSize()
        }
    }

    private func expiryCaption(_ date: Date?, now: Date) -> String {
        guard let date else { return "expiry not reported" }
        let monthDay = date.formatted(.dateTime.month(.abbreviated).day())
        if expiresSoon(date, now: now) {
            let daysLeft = Int(max(0, date.timeIntervalSince(now) / 86_400).rounded(.up))
            return "next \(monthDay) · \(daysLeft)d"
        }
        return inventory.reportedAvailableCount == 1 ? "expires \(monthDay)" : "next \(monthDay)"
    }

    private func expiresSoon(_ date: Date, now: Date) -> Bool {
        date.timeIntervalSince(now) < 7 * 86_400
    }
}

#Preview("Reset credits") {
    GlassSheet {
        ResetCreditsSection(inventory: ResetCreditInventory(
            reportedAvailableCount: 3,
            availableCredits: [
                ResetCredit(id: "a", count: 2, expiresAt: .now.addingTimeInterval(3 * 86_400)),
                ResetCredit(id: "b"),
            ],
            fetchedAt: .now
        ))
    }
    .padding(11)
    .frame(width: PopoverLayout.width)
}
