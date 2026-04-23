import SwiftUI

/// A card displaying a single provider's usage information.
struct ProviderCard: View {
    let provider: any UsageProvider
    @Environment(UsageManager.self) private var manager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: icon + name + plan badge
            HStack(spacing: 8) {
                ProviderIcon(kind: provider.kind, size: 20)

                Text(provider.kind.displayName)
                    .font(.system(size: 13, weight: .semibold))

                Spacer()

                if let planName = provider.snapshot?.planName {
                    Text(planName)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary)
                        .clipShape(Capsule())
                }
            }

            // Content
            if provider.isLoading && provider.snapshot == nil {
                loadingView
            } else if let error = provider.error, provider.snapshot == nil {
                errorView(error)
            } else if let snapshot = provider.snapshot {
                snapshotContent(snapshot)
            } else {
                notConfiguredView
            }
        }
        .padding(12)
        .background(.quinary)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Content variants

    @ViewBuilder
    private func snapshotContent(_ snapshot: UsageSnapshot) -> some View {
        switch provider.kind {
        case .claude, .codex:
            rollingWindowContent(snapshot)
        case .cursor:
            billingCycleContent(snapshot)
        case .antigravity:
            perModelContent(snapshot)
        }

        monthlyCostRow(snapshot)
        if let error = provider.error {
            staleWarningRow(error)
        }
        cardFooter(snapshot)
    }

    /// Inline warning shown below stale data (e.g. during a 429 cooldown) so
    /// the user still sees the last-known usage but knows it isn't fresh.
    private func staleWarningRow(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 9))
                .foregroundStyle(.yellow)
            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Spacer()
        }
        .padding(.top, 2)
    }

    // MARK: - Monthly cost row

    @ViewBuilder
    private func monthlyCostRow(_ snapshot: UsageSnapshot) -> some View {
        if manager.showEstimatedCost, let cost = snapshot.monthlyEstimatedCost {
            let isEstimate = provider.kind != .cursor
            HStack(spacing: 4) {
                Image(systemName: "dollarsign.circle")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("This month")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if isEstimate {
                    Image(systemName: "info.circle")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .help(Self.estimateTooltip)
                }
                Spacer()
                Text(Self.formatCost(cost, estimated: isEstimate))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
    }

    private static let estimateTooltip = """
    Estimated from this Mac's local CLI session logs × API pricing.
    Usage from other machines on the same account is not included.
    """

    private static func formatCost(_ amount: Double, estimated: Bool) -> String {
        let prefix = estimated ? "~$" : "$"
        return prefix + String(format: "%.2f", amount)
    }

    // MARK: - Claude / Codex: rolling windows

    @ViewBuilder
    private func rollingWindowContent(_ snapshot: UsageSnapshot) -> some View {
        if let session = snapshot.sessionUsage {
            usageBar(
                label: "Session (5h)",
                percent: session.percentUsed,
                resetCountdown: session.resetCountdown
            )
        }
        if let weekly = snapshot.weeklyUsage {
            usageBar(
                label: "Weekly (7d)",
                percent: weekly.percentUsed,
                resetCountdown: weekly.resetCountdown
            )
        }
    }

    // MARK: - Cursor: billing cycle

    @ViewBuilder
    private func billingCycleContent(_ snapshot: UsageSnapshot) -> some View {
        if let spent = snapshot.spentAmount {
            usageBar(
                label: "Included (\(spent.formatted))",
                percent: snapshot.totalUsagePercent ?? 0
            )
        }

        if let onDemand = snapshot.onDemandSpend {
            if let limit = onDemand.limit, limit > 0 {
                usageBar(
                    label: "On-Demand (\(onDemand.formatted))",
                    percent: onDemand.amount / limit * 100
                )
            } else {
                HStack {
                    Text("On-Demand")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(onDemand.formatted)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: - Antigravity: per-model bars

    @ViewBuilder
    private func perModelContent(_ snapshot: UsageSnapshot) -> some View {
        ForEach(snapshot.modelQuotas) { quota in
            usageBar(label: quota.label, percent: quota.percentUsed)
        }
    }

    // MARK: - Unified footer

    private func cardFooter(_ snapshot: UsageSnapshot) -> some View {
        HStack {
            if let reset = resetText(snapshot) {
                Label(reset, systemImage: "clock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let email = snapshot.email {
                Text(email)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private func resetText(_ snapshot: UsageSnapshot) -> String? {
        switch provider.kind {
        case .claude, .codex:
            // Claude/Codex show per-window countdowns inline under each
            // usage bar, so the footer no longer duplicates the 5h reset.
            return nil
        case .cursor:
            guard let cycleEnd = snapshot.billingCycleEnd else { return nil }
            let daysLeft = Calendar.current.dateComponents([.day], from: .now, to: cycleEnd).day ?? 0
            return "\(max(0, daysLeft))d left"
        case .antigravity:
            guard let resetTime = snapshot.modelQuotas.first?.resetsAt else { return nil }
            return UsageWindow(percentUsed: 0, resetsAt: resetTime).resetCountdown
        }
    }

    // MARK: - Shared components

    private func usageBar(
        label: String,
        percent: Double,
        resetCountdown: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(percent))%")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            ProgressBar(percent: percent)

            if let resetCountdown {
                Label(resetCountdown, systemImage: "clock")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var loadingView: some View {
        HStack {
            ProgressView()
                .scaleEffect(0.7)
            Text("Loading…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 8)
    }

    private func errorView(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.yellow)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer()

            Button {
                Task { await provider.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var notConfiguredView: some View {
        Text("Not configured")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.vertical, 4)
    }
}

// MARK: - Progress Bar

struct ProgressBar: View {
    let percent: Double
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)

                Capsule()
                    .fill(barColor)
                    .frame(width: max(0, geo.size.width * min(percent, 100) / 100))
                    .animation(.easeInOut(duration: 0.4), value: percent)
            }
        }
        .frame(height: height)
    }

    private var barColor: Color {
        if percent > 85 { return .red }
        if percent > 60 { return .yellow }
        return .green
    }
}

