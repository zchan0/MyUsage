import SwiftUI

/// Provider detail page for the 400pt capacity console. Rolling limits become
/// two large side-by-side instruments; provider-specific billing and history
/// stay below them so cost never competes with capacity for first attention.
struct ProviderDeck: View {
    let provider: any UsageProvider
    var showsHeader = true

    @Environment(UsageManager.self) private var manager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader { providerHeader }
            content
        }
    }

    private var providerHeader: some View {
        HStack(spacing: 9) {
            ProviderIconTile(kind: provider.kind, size: 27, glyph: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(provider.kind.displayName)
                    .font(.system(size: 14, weight: .semibold))
                if let plan = provider.snapshot?.planName {
                    Text(plan)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary.opacity(0.72))
                }
            }

            Spacer(minLength: 8)

            if let email = provider.snapshot?.email {
                Text(email)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 150)
            }
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 62)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
        }
    }

    @ViewBuilder
    private var content: some View {
        if provider.isLoading && provider.snapshot == nil {
            stateRow(icon: nil, text: "Loading…", loading: true)
        } else if let error = provider.error, provider.snapshot == nil {
            stateRow(icon: "exclamationmark.triangle", text: error)
        } else if let snapshot = provider.snapshot {
            snapshotContent(snapshot)
        } else {
            stateRow(icon: "questionmark.circle", text: "Not configured")
        }
    }

    private func snapshotContent(_ snapshot: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if provider.kind == .claude || provider.kind == .codex {
                rollingInstruments(snapshot)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 18)
            } else {
                ProviderCardLimits(kind: provider.kind, snapshot: snapshot)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 18)
            }

            if provider.kind == .codex {
                sectionDivider
                Group {
                    if let inventory = snapshot.resetCredits {
                        ResetCreditsSection(inventory: inventory)
                    } else {
                        HStack(alignment: .firstTextBaseline) {
                            Text("RESET CREDITS")
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            Spacer()
                            Text("Unavailable")
                                .font(.system(size: 10, design: .monospaced))
                        }
                        .foregroundStyle(.secondary.opacity(0.72))
                        .help("Codex did not return reset-credit inventory. No count is assumed.")
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 17)
            }

            if manager.showEstimatedCost {
                detailCost(snapshot)
            }

            if let error = provider.error {
                sectionDivider
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Retry") { Task { await provider.refresh() } }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.tint)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 13)
            }

            HStack {
                Text("Updated")
                Spacer()
                Text(snapshot.lastRefreshed, style: .relative)
            }
            .font(.system(size: 8.5, design: .monospaced))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .overlay(alignment: .top) { sectionDivider }
        }
    }

    @ViewBuilder
    private func rollingInstruments(_ snapshot: UsageSnapshot) -> some View {
        let metrics = CapacityFocus.metrics(providerKind: provider.kind, snapshot: snapshot)
        if metrics.isEmpty {
            Text("No rolling limits reported")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                    DeckLimitInstrument(metric: metric)
                        .padding(.leading, index == 0 ? 0 : 16)
                        .padding(.trailing, index == metrics.count - 1 ? 0 : 16)
                        .frame(maxWidth: .infinity, alignment: .topLeading)

                    if index < metrics.count - 1 {
                        Rectangle()
                            .fill(Color.primary.opacity(0.08))
                            .frame(width: 0.5, height: 126)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func detailCost(_ snapshot: UsageSnapshot) -> some View {
        let series = manager.ledger.dailyCosts[provider.kind]
        let hasChart = series?.isEmpty == false
        if snapshot.monthlyEstimatedCost != nil || hasChart || provider.kind == .cursor {
            sectionDivider
            VStack(alignment: .leading, spacing: 12) {
                ProviderCardCostRow(kind: provider.kind, snapshot: snapshot, showsDivider: false)
                if let series, !series.isEmpty {
                    DailyCostChart(series: series)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
    }

    private var sectionDivider: some View {
        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
    }

    private func stateRow(icon: String?, text: String, loading: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if loading {
                ProgressView().scaleEffect(0.7)
            } else if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if !loading {
                Button { Task { await provider.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(18)
    }
}

private struct DeckLimitInstrument: View {
    let metric: CapacityFocus.Metric

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(metric.label)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let pace = metric.pacePercent {
                    Text("pace \(Int(pace.rounded()))%")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            Text("\(Int(metric.percentUsed.rounded()))%")
                .font(.system(size: 30, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(LimitSafety.level(for: metric.percentUsed).accent)
                .padding(.top, 8)

            ProgressTrack(
                percent: metric.percentUsed,
                pacePercent: metric.pacePercent,
                level: LimitSafety.level(for: metric.percentUsed),
                height: 7
            )
            .padding(.top, 11)

            HStack {
                Text("0")
                Spacer()
                Text("50")
                Spacer()
                Text("100")
            }
            .font(.system(size: 7.5, design: .monospaced))
            .foregroundStyle(.tertiary)
            .padding(.top, 4)

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(resetText)
                Spacer(minLength: 4)
                if let projected = metric.projectedFinalPercent, projected > 100 {
                    Text("projected \(Int(projected.rounded()))%")
                        .foregroundStyle(LimitBar.warnAccent)
                }
            }
            .font(.system(size: 8.5, design: .monospaced))
            .foregroundStyle(.secondary.opacity(0.72))
            .lineLimit(1)
            .padding(.top, 8)
        }
    }

    private var resetText: String {
        guard let reset = metric.resetsAt else { return "Reset not reported" }
        return "resets in \(OverviewSummary.shortCountdown(until: reset))"
    }
}

#if DEBUG
#Preview("Codex Deck") {
    let manager = PreviewFixtures.manager(providerCount: 2)
    ProviderDeck(provider: manager.orderedProviders.first { $0.kind == .codex }!)
        .environment(manager)
        .frame(width: 400)
}
#endif
