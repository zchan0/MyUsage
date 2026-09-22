import SwiftUI
import Charts

struct GatewayOverviewRow: View {
    let provider: GatewayProvider
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let block = provider.snapshot.summary
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                ProviderInstanceIcon(source: provider.source, size: 25, glyph: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.displayName).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Text("\(provider.connection.vendor.displayName) · \(block.value?.scope.label ?? "Not connected")")
                        .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                if let percent = block.value?.percentUsed {
                    Text("\(Int(min(percent, 999)))%")
                        .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    Text("used").font(.system(size: 9.5)).foregroundStyle(.secondary)
                } else if let spend = block.value?.spend {
                    Text(GatewayFormatting.money(spend)).font(.system(size: 12, weight: .semibold, design: .monospaced))
                }
            }
            if let percent = block.value?.percentUsed {
                ProgressTrack(percent: percent, pacePercent: nil, level: LimitSafety.level(for: percent),
                              height: 4, tint: provider.source.usageTint(for: scheme))
            }
            if let issue = block.issue {
                Text(block.value == nil ? issue.message : "Update failed · Showing previous usage")
                    .font(.system(size: 9.5)).foregroundStyle(.secondary)
            } else if let summary = block.value {
                HStack {
                    Text(summary.periodLabel)
                    Spacer()
                    if let left = summary.remaining { Text("\(GatewayFormatting.money(left)) left") }
                }.font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(0.08)).frame(height: 0.5) }
    }
}

struct GatewayProviderDeck: View {
    let provider: GatewayProvider
    @Environment(\.colorScheme) private var scheme
    @Environment(\.popoverPresentation) private var presentation
    private struct LoadID: Equatable { let connection: GatewayConnection; let isVisible: Bool }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                ProviderInstanceIcon(source: provider.source, size: 27, glyph: 15)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                    Text("\(provider.connection.vendor.displayName) · \(provider.connection.baseURL.host ?? "")")
                        .font(.system(size: 9.5)).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: 4)
            }.padding(.horizontal, 16).frame(minHeight: 54)
            divider
            if let summary = provider.snapshot.summary.value {
                summarySection(summary)
            } else {
                HStack(spacing: 8) {
                    if provider.isLoading { ProgressView().controlSize(.small) }
                    Text(provider.isLoading ? "Loading…" : (provider.error ?? "Not connected"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let issue = provider.snapshot.summary.issue, provider.snapshot.summary.value != nil {
                status(issue.message)
            }
            if let history = provider.snapshot.history.value {
                historySection(history)
            } else if provider.isLoadingHistory {
                HStack { ProgressView().controlSize(.small); Text("Loading model usage…").font(.system(size: 11)) }.padding(16)
            } else if let issue = provider.snapshot.history.issue, issue != .notChecked {
                status("Model usage · \(issue.message)")
            }
        }
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
            HStack(alignment: .firstTextBaseline) {
                Text(summary.scope.label + " budget").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if let percent = summary.percentUsed {
                    Text("\(Int(min(percent, 999)))%")
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    Text("used").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            if let percent = summary.percentUsed {
                ProgressTrack(percent: percent, pacePercent: nil, level: LimitSafety.level(for: percent),
                              height: 6, tint: provider.source.usageTint(for: scheme))
            }
            if summary.percentUsed == nil, let spend = summary.spend {
                HStack {
                    Text(summary.periodLabel).font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Text(GatewayFormatting.money(spend, currency: summary.currency))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                }
            }
            switch summary.budget {
            case .finite(let limit):
                Text(limit == 0 ? "No budget available" : "\(GatewayFormatting.money(summary.spend)) / \(GatewayFormatting.money(limit))")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            case .unbounded: Text("No budget limit").font(.system(size: 10)).foregroundStyle(.secondary)
            case .unspecified: Text("Budget limit not reported").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack {
                if let reset = summary.resetsAt {
                    Text("Resets \(reset.formatted(date: .abbreviated, time: .shortened))")
                } else { Text("Reset not reported") }
                Spacer(minLength: 4)
                if let left = summary.remaining { Text("\(GatewayFormatting.money(left)) left") }
            }.font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
        }.padding(.horizontal, 16).padding(.vertical, 12)
        .overlay(alignment: .bottom) { divider }
    }

    private func historySection(_ history: GatewayHistory) -> some View {
        let totals = history.totals
        let hasCost = totals.cost != nil
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(history.complete ? "This month" : "This month · Partial")
                    .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(modelReadout(totals))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
            }
            Text("\(history.startDate) – \(history.endDate) · UTC · \(history.scope.label)")
                .font(.system(size: 8.5)).foregroundStyle(.tertiary)
            if let issue = provider.snapshot.history.issue {
                Text(issue.message).font(.system(size: 9.5)).foregroundStyle(.secondary)
            }
            if !history.complete {
                Text("Some records are missing; totals cover only the records shown.")
                    .font(.system(size: 9.5)).foregroundStyle(.secondary)
            }
            if history.days.isEmpty {
                Text("No usage records in this period").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                if hasCost || totals.totalTokens != nil {
                    Chart(history.days) { day in
                        if let date = GatewayCalendar.parseDay(day.date),
                           let value = hasCost ? day.metrics.cost.map({ NSDecimalNumber(decimal: $0).doubleValue }) : day.metrics.totalTokens.map(Double.init) {
                            BarMark(x: .value("Date", date, unit: .day), y: .value(hasCost ? "USD" : "Tokens", value), width: 6)
                                .foregroundStyle(provider.source.usageTint(for: scheme)).cornerRadius(1.5)
                        }
                    }
                    .chartYAxis(.hidden)
                    .chartXAxis(.hidden)
                    .chartXScale(domain: chartDateRange(history))
                    .frame(height: 82)
                    .accessibilityLabel(hasCost ? "Daily reported cost in USD" : "Daily token usage")
                    HStack {
                        Text(String(history.startDate.suffix(5)))
                        Spacer()
                        Text(String(history.endDate.suffix(5)))
                    }.font(.system(size: 8.5)).foregroundStyle(.tertiary)
                }

                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(history.models, id: \.name) { model in
                            HStack(spacing: 4) {
                                Circle().fill(provider.source.usageTint(for: scheme)).frame(width: 6, height: 6)
                                Text(model.name).font(.system(size: 9, weight: .medium)).lineLimit(1).help(model.name)
                                Spacer(minLength: 6)
                                Text(modelReadout(model.metrics))
                                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                            }.frame(height: 14).foregroundStyle(.secondary)
                        }
                    }
                }.frame(height: CGFloat(min(history.models.count, 8)) * 18)
                if !history.hasCompleteModelBreakdown, !history.models.isEmpty {
                    Text("Model breakdown is incomplete.").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                divider
                if totals.totalTokens != nil || totals.inputTokens != nil || totals.outputTokens != nil || totals.cacheReadTokens != nil {
                    HStack(spacing: 0) {
                        tokenStat("Total", totals.totalTokens)
                        tokenStat("Input", totals.inputTokens)
                        tokenStat("Output", totals.outputTokens)
                        tokenStat("Cache read", totals.cacheReadTokens)
                    }
                }
            }
        }.padding(.horizontal, 16).padding(.vertical, 14)
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
            Text(label).font(.system(size: 8.5)).foregroundStyle(.tertiary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func status(_ message: String) -> some View {
        Text(message).font(.system(size: 9.5)).foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading)
    }
    private var divider: some View { Rectangle().fill(.primary.opacity(0.08)).frame(height: 0.5) }
}
