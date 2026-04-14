import SwiftUI

/// A card displaying a single provider's usage information.
struct ProviderCard: View {
    let provider: any UsageProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: icon + name + plan badge
            HStack(spacing: 8) {
                Image(systemName: provider.kind.iconName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(provider.kind.accentColor)
                    .frame(width: 20, height: 20)

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
    }

    // MARK: - Claude / Codex: rolling windows

    @ViewBuilder
    private func rollingWindowContent(_ snapshot: UsageSnapshot) -> some View {
        HStack(spacing: 12) {
            // Circular ring for session
            if let session = snapshot.sessionUsage {
                CircularProgressRing(
                    percent: session.percentUsed,
                    size: 44
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                if let session = snapshot.sessionUsage {
                    usageBar(label: "Session (5h)", percent: session.percentUsed)
                }
                if let weekly = snapshot.weeklyUsage {
                    usageBar(label: "Weekly (7d)", percent: weekly.percentUsed)
                }
            }
        }

        // Bottom info
        HStack {
            if let countdown = snapshot.sessionUsage?.resetCountdown {
                Label(countdown, systemImage: "clock")
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

    // MARK: - Cursor: billing cycle

    @ViewBuilder
    private func billingCycleContent(_ snapshot: UsageSnapshot) -> some View {
        if let total = snapshot.totalUsagePercent {
            usageBar(label: "Total Usage", percent: total)
        }

        // Auto / API split
        if let auto_ = snapshot.autoUsagePercent, let api = snapshot.apiUsagePercent {
            HStack(spacing: 4) {
                Text("Auto: \(Int(auto_))%")
                Text("·")
                Text("API: \(Int(api))%")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }

        // Spending
        HStack {
            if let spent = snapshot.spentAmount {
                Text(spent.formatted)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }

            Spacer()

            if let cycleEnd = snapshot.billingCycleEnd {
                let daysLeft = Calendar.current.dateComponents([.day], from: .now, to: cycleEnd).day ?? 0
                Label("\(max(0, daysLeft))d left", systemImage: "calendar")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Antigravity: per-model bars

    @ViewBuilder
    private func perModelContent(_ snapshot: UsageSnapshot) -> some View {
        ForEach(snapshot.modelQuotas) { quota in
            usageBar(label: quota.label, percent: quota.percentUsed)
        }

        if let resetTime = snapshot.modelQuotas.first?.resetsAt {
            let countdown = UsageWindow(percentUsed: 0, resetsAt: resetTime).resetCountdown
            if let countdown {
                Label("Resets in \(countdown)", systemImage: "clock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Shared components

    private func usageBar(label: String, percent: Double) -> some View {
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

// MARK: - Circular Progress Ring

struct CircularProgressRing: View {
    let percent: Double
    var size: CGFloat = 44
    private let lineWidth: CGFloat = 4

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: min(percent, 100) / 100)
                .stroke(ringColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))

            Text("\(Int(percent))%")
                .font(.system(size: size * 0.24, weight: .semibold, design: .monospaced))
        }
        .frame(width: size, height: size)
    }

    private var ringColor: Color {
        if percent > 85 { return .red }
        if percent > 60 { return .yellow }
        return .green
    }
}
