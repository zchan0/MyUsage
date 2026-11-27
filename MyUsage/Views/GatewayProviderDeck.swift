import SwiftUI
import Charts

struct GatewayProviderDeck: View {
    let provider: GatewayProvider
    @Environment(\.colorScheme) private var scheme
    @Environment(\.popoverPresentation) private var presentation
    private struct LoadID: Equatable { let connection: GatewayConnection; let isVisible: Bool }

    private var palette: PopoverPalette { PopoverPalette(scheme) }

    var body: some View {
        VStack(spacing: 9) {
            GlassSheet {
                VStack(alignment: .leading, spacing: 11) {
                    HStack(spacing: 8) {
                        ProviderInstanceIcon(source: provider.source, size: 24, glyph: 14)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.displayName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(palette.inkPrimary)
                                .lineLimit(1)
                            Text("\(provider.connection.vendor.displayName) · \(provider.connection.baseURL.host ?? "")")
                                .font(.system(size: 10.5))
                                .foregroundStyle(palette.inkTertiary)
                                .lineLimit(1)
                        }
                    }
                    if let summary = provider.snapshot.summary.value {
                        summarySection(summary)
                        if let issue = provider.snapshot.summary.issue {
                            status(issue.message)
                        }
                    } else {
                        HStack(spacing: 8) {
                            if provider.isLoading { ProgressView().controlSize(.small) }
                            status(provider.isLoading ? "Loading…" : (provider.error ?? "Not connected"))
                        }
                    }
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 14)
            }

            if let history = provider.snapshot.history.value {
                GlassSheet { historySection(history) }
            } else if provider.isLoadingHistory {
                historyStatus("Loading model usage…", loading: true)
            } else if let issue = provider.snapshot.history.issue, issue != .notChecked {
                historyStatus("Model usage · \(issue.message)")
            }
        }
        .padding(.horizontal, PopoverLayout.horizontalPadding)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .task(id: LoadID(connection: provider.connection, isVisible: presentation?.isVisible ?? true)) {
            let visible = presentation?.isVisible ?? true
            provider.isHistoryVisible = visible
            guard visible else { return }
            if provider.snapshot.summary.value == nil { await provider.refresh() }
            await provider.loadHistory()
        }
        .onDisappear { provider.isHistoryVisible = false }
    }

    private func summarySection(_ summary: GatewaySummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let percent = summary.percentUsed {
                QuotaRunwayRow(win: summary.scope.label, percent: percent, wide: true)
            } else {
                Text(summary.scope.label + " budget")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(palette.inkSecondary)
            }
            if summary.percentUsed == nil, let spend = summary.spend {
                HStack {
                    Text(summary.periodLabel).font(.system(size: 10)).foregroundStyle(palette.inkSecondary)
                    Spacer()
                    Text(GatewayFormatting.money(spend, currency: summary.currency))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                }
            }
            switch summary.budget {
            case .finite(let limit):
                Text(limit == 0 ? "No budget available" : "\(GatewayFormatting.money(summary.spend)) / \(GatewayFormatting.money(limit))")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(palette.inkSecondary)
            case .unbounded: Text("No budget limit").font(.system(size: 10)).foregroundStyle(palette.inkSecondary)
            case .unspecified: Text("Budget limit not reported").font(.system(size: 10)).foregroundStyle(palette.inkSecondary)
            }
            HStack {
                if let reset = summary.resetsAt {
                    Text("Resets \(reset.formatted(date: .abbreviated, time: .shortened))")
                } else { Text("Reset not reported") }
                Spacer(minLength: 4)
                if let left = summary.remaining { Text("\(GatewayFormatting.money(left)) left") }
            }.font(.system(size: 9, design: .monospaced)).foregroundStyle(palette.inkTertiary)
        }
    }

    private func historySection(_ history: GatewayHistory) -> some View {
        let totals = history.totals
        let hasCost = totals.cost != nil
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(history.complete ? "This month" : "This month · Partial")
                    .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(palette.inkSecondary)
                Spacer()
                Text(modelReadout(totals))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
            }
            Text("\(history.startDate) – \(history.endDate) · UTC · \(history.scope.label)")
                .font(.system(size: 8.5)).foregroundStyle(palette.inkTertiary)
            if let issue = provider.snapshot.history.issue {
                Text(issue.message).font(.system(size: 9.5)).foregroundStyle(palette.inkSecondary)
            }
            if !history.complete {
                Text("Some records are missing; totals cover only the records shown.")
                    .font(.system(size: 9.5)).foregroundStyle(palette.inkSecondary)
            }
            if history.days.isEmpty {
                Text("No usage records in this period").font(.system(size: 11)).foregroundStyle(palette.inkSecondary)
            } else {
                if hasCost || totals.totalTokens != nil {
                    Chart(history.days) { day in
                        if let date = GatewayCalendar.parseDay(day.date),
                           let value = hasCost ? day.metrics.cost.map({ NSDecimalNumber(decimal: $0).doubleValue }) : day.metrics.totalTokens.map(Double.init) {
                            BarMark(x: .value("Date", date, unit: .day), y: .value(hasCost ? "USD" : "Tokens", value), width: 6)
                                .foregroundStyle(palette.sparkFocus.opacity(0.62)).cornerRadius(1.5)
                        }
                    }
                    .chartYAxis(.hidden)
                    .chartXAxis(.hidden)
                    .chartXScale(domain: chartDateRange(history))
                    .frame(height: 50)
                    .animation(PopoverMotion.meter, value: history.days.map(\.metrics))
                    .accessibilityLabel(hasCost ? "Daily reported cost in USD" : "Daily token usage")
                    HStack {
                        Text(String(history.startDate.suffix(5)))
                        Spacer()
                        Text(String(history.endDate.suffix(5)))
                    }.font(.system(size: 8.5)).foregroundStyle(palette.inkTertiary)
                }

                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(history.models, id: \.name) { model in
                            HStack(spacing: 4) {
                                Circle().fill(palette.sparkIdle).frame(width: 6, height: 6)
                                Text(model.name).font(.system(size: 9, weight: .medium)).lineLimit(1).help(model.name)
                                Spacer(minLength: 6)
                                Text(modelReadout(model.metrics))
                                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                            }.frame(height: 14).foregroundStyle(palette.inkSecondary)
                        }
                    }
                }.frame(height: CGFloat(min(history.models.count, 8)) * 18)
                if !history.hasCompleteModelBreakdown, !history.models.isEmpty {
                    Text("Model breakdown is incomplete.").font(.system(size: 9)).foregroundStyle(palette.inkSecondary)
                }
                PopoverHairline()
                if totals.totalTokens != nil || totals.inputTokens != nil || totals.outputTokens != nil || totals.cacheReadTokens != nil {
                    HStack(spacing: 0) {
                        tokenStat("Total", totals.totalTokens)
                        tokenStat("Input", totals.inputTokens)
                        tokenStat("Output", totals.outputTokens)
                        tokenStat("Cache read", totals.cacheReadTokens)
                    }
                }
            }
        }
        .foregroundStyle(palette.inkPrimary)
        .padding(.horizontal, 15)
        .padding(.vertical, 14)
    }
    private func modelReadout(_ metrics: GatewayMetrics) -> String {
        if let cost = metrics.cost { return GatewayFormatting.modelCost(cost) }
        if let tokens = metrics.totalTokens { return "\(GatewayFormatting.count(tokens)) tokens" }
        if let requests = metrics.requests { return "\(GatewayFormatting.count(requests)) requests" }
        return "—"
    }
    private func chartDateRange(_ history: GatewayHistory) -> ClosedRange<Date> {
        let start = GatewayCalendar.parseDay(history.startDate) ?? .now
        let end = (GatewayCalendar.parseDay(history.endDate) ?? start).addingTimeInterval(86_400)
        return start...max(start.addingTimeInterval(86_400), end)
    }
    private func tokenStat(_ label: String, _ value: Int64?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(GatewayFormatting.count(value)).font(.system(size: 10.5, weight: .semibold, design: .monospaced))
            Text(label).font(.system(size: 8.5)).foregroundStyle(palette.inkTertiary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func status(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 10.5))
            .foregroundStyle(palette.inkSecondary)
    }

    private func historyStatus(_ message: String, loading: Bool = false) -> some View {
        GlassSheet {
            HStack(spacing: 8) {
                if loading { ProgressView().controlSize(.small) }
                status(message)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 14)
        }
    }
}
