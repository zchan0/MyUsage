import SwiftUI

/// Provider detail page for the compact capacity console. Rolling limits use
/// full-width rows so their pace markers and reset context stay legible even
/// in the narrower popover; billing and history remain below them.
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
            ProviderIconTile(kind: provider.kind, size: 24, glyph: 14)

            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(provider.kind.displayName)
                    .font(.system(size: 13.5, weight: .semibold))
                if let plan = provider.snapshot?.planName {
                    PlanPill(text: plan)
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
        .padding(.horizontal, 16)
        .frame(minHeight: 54)
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
            if !showsHeader {
                compactContext(snapshot)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
            }

            if provider.kind == .claude || provider.kind == .codex {
                rollingInstruments(snapshot)
                    .padding(.horizontal, 16)
                    .padding(.top, showsHeader ? 22 : 14)
                    .padding(.bottom, 22)
            } else {
                ProviderCardLimits(kind: provider.kind, snapshot: snapshot)
                    .padding(.horizontal, 16)
                    .padding(.top, showsHeader ? 22 : 14)
                    .padding(.bottom, 22)
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
                .padding(.horizontal, 16)
                .padding(.vertical, 21)
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
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
        }
    }

    private func compactContext(_ snapshot: UsageSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text("\(provider.kind.displayName.uppercased()) LIMITS")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(0.35)
                .foregroundStyle(.secondary.opacity(0.82))

            Spacer(minLength: 8)

            if let plan = snapshot.planName {
                PlanPill(text: plan)
            }
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
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                    DeckLimitInstrument(metric: metric)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if index < metrics.count - 1 {
                        Rectangle()
                            .fill(Color.primary.opacity(0.08))
                            .frame(height: 0.5)
                            .padding(.vertical, 17)
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
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
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
        .padding(20)
    }
}

private struct DeckLimitInstrument: View {
    let metric: CapacityFocus.Metric

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Text(metric.label)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .padding(.top, 2)

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("\(Int(metric.percentUsed.rounded()))%")
                            .font(.system(size: 18.5, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(LimitSafety.level(for: metric.percentUsed).accent)
                        Text("used")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary.opacity(0.72))
                    }

                    if let pace = metric.pacePercent {
                        PaceReadout(percentUsed: metric.percentUsed, pacePercent: pace)
                    }

                    if let projected = metric.projectedFinalPercent, projected > 100 {
                        Text("Projected \(Int(projected.rounded()))% at reset")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(LimitBar.warnAccent)
                    }
                }
            }

            ProgressTrack(
                percent: metric.percentUsed,
                pacePercent: metric.pacePercent,
                level: LimitSafety.level(for: metric.percentUsed),
                height: 6
            )
            .padding(.top, 12)

            ResetCountdownReadout(resetsAt: metric.resetsAt)
                .padding(.top, 12)
        }
    }
}

#if DEBUG
#Preview("Codex Deck") {
    let manager = PreviewFixtures.manager(providerCount: 2)
    ProviderDeck(provider: manager.orderedProviders.first { $0.kind == .codex }!)
        .environment(manager)
        .frame(width: PopoverLayout.width)
}
#endif
