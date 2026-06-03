import SwiftUI

/// Settings → Cost (spec 16). Two stacked sections:
///   1. *This month — Claude Code*: cache hit rate + per-bucket
///      token / dollar split, derived from the snapshot's
///      `monthlyTokenBreakdown`. Hidden when no breakdown exists.
///   2. *Pricing*: source provenance, auto-update toggle, and a
///      manual "Check for updates" button.
///
/// The first time an upgraded user lands here, a one-time
/// confirmation dialog asks whether to allow remote pricing fetches —
/// fresh installs default to opted-in and never see the dialog.
struct CostTab: View {
    @Environment(UsageManager.self) private var manager
    @State private var loader = PricingLoader.shared
    @State private var fetcher = PricingRemoteFetcher.shared

    @State private var isCheckingForUpdates = false
    @State private var showOptInPrompt = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                claudeSection
                pricingSection

                Text("Cache hit rate is `cache_read / (input + cache_creation + cache_read)`. Output tokens are intentionally excluded — they're not cacheable.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
        .onAppear {
            if !loader.optInDecided {
                showOptInPrompt = true
            }
        }
        .confirmationDialog(
            "Allow MyUsage to fetch pricing updates from GitHub?",
            isPresented: $showOptInPrompt,
            titleVisibility: .visible
        ) {
            Button("Allow") { loader.resolveFirstRunOptIn(allow: true) }
            Button("Don't allow", role: .cancel) {
                loader.resolveFirstRunOptIn(allow: false)
            }
        } message: {
            Text("Pricing is fetched once a week from a static JSON file in the MyUsage repository. No identifying data is sent. You can change this later.")
        }
    }

    // MARK: - Claude breakdown

    @ViewBuilder
    private var claudeSection: some View {
        if let claude = manager.providers.first(where: { $0.kind == .claude }),
           claude.isEnabled,
           let breakdown = claude.snapshot?.monthlyTokenBreakdown {
            SettingsCard("This month — Claude Code") {
                if breakdown.isEmpty {
                    Text("No usage this month")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 6)
                } else {
                    breakdownContent(breakdown)
                }
            }
        }
    }

    @ViewBuilder
    private func breakdownContent(_ breakdown: TokenBreakdown) -> some View {
        let catalog = PricingCatalog.shared
        let provider = manager.providers.first(where: { $0.kind == .claude })
        let perModel = ClaudeMonthlyTokens.tokensByModel(for: provider)
        let buckets = CostCalculator.perBucketTotalCost(of: perModel, catalog: catalog)

        Group {
            SettingsRow("Real total tokens", caption: "input + output + cache writes + cache reads") {
                Text(formatTokens(breakdown.realTotal))
                    .font(.system(size: 12.5, weight: .medium, design: .monospaced))
            }
            CardDivider()
            SettingsRow("Cache hit rate", caption: "cache_read / cacheable input") {
                Text(formatPercent(breakdown.cacheHitRate))
                    .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(hitRateColor(breakdown.cacheHitRate))
            }
            CardDivider()

            bucketRow("Fresh input", tokens: breakdown.freshInput, dollars: buckets.freshInput)
            CardDivider()
            bucketRow("Output", tokens: breakdown.output, dollars: buckets.output)
            CardDivider()
            bucketRow("Cache write", tokens: breakdown.cacheCreation, dollars: buckets.cacheCreation)
            CardDivider()
            bucketRow("Cache read", tokens: breakdown.cacheRead, dollars: buckets.cacheRead)

            if breakdown.preComputedCost > 0 {
                CardDivider()
                SettingsRow(
                    "Pre-priced by Claude Code",
                    caption: "Rows that carried a server-computed cost; not split into buckets."
                ) {
                    Text(formatDollars(breakdown.preComputedCost))
                        .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                }
            }

            CardDivider()
            SettingsRow("Total") {
                let total = buckets.total + breakdown.preComputedCost
                Text(formatDollars(total))
                    .font(.system(size: 13.5, weight: .semibold, design: .monospaced))
            }
        }
    }

    private func bucketRow(_ label: String, tokens: Int, dollars: Double) -> some View {
        SettingsRow(label) {
            HStack(spacing: 14) {
                Text(formatTokens(tokens))
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(formatDollars(dollars))
                    .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                    .frame(minWidth: 64, alignment: .trailing)
            }
        }
    }

    // MARK: - Pricing block

    @ViewBuilder
    private var pricingSection: some View {
        SettingsCard("Pricing") {
            SettingsRow(
                "Auto-update from remote",
                caption: "Fetch the latest pricing table from GitHub once a week."
            ) {
                Toggle("", isOn: Binding(
                    get: { loader.autoUpdatePricing },
                    set: { loader.autoUpdatePricing = $0 }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            CardDivider()
            SettingsRow("Source", caption: sourceCaption) {
                if loader.autoUpdatePricing {
                    Button {
                        Task { await checkForUpdates() }
                    } label: {
                        if isCheckingForUpdates {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Check for updates")
                        }
                    }
                    .controlSize(.small)
                    .disabled(isCheckingForUpdates)
                } else {
                    Text("Disabled")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.tertiary)
                }
            }
            CardDivider()
            SettingsRow("Currently using") {
                Text(currentlyUsingText)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sourceCaption: String {
        "raw.githubusercontent.com/zchan0/MyUsage/main/pricing/v1.json"
    }

    private var currentlyUsingText: String {
        switch loader.source {
        case .bundled:
            if let updated = loader.bundledUpdated {
                return "bundled (built \(updated))"
            }
            return "bundled"
        case .cachedRemote(let updatedAt, let fetchedAt):
            return "remote · cached \(shortDate(fetchedAt))"
                + (updatedAt.map { " · updated \(shortDate($0))" } ?? "")
        case .freshRemote(let updatedAt, let fetchedAt):
            return "remote · fetched \(shortDate(fetchedAt))"
                + (updatedAt.map { " · updated \(shortDate($0))" } ?? "")
        }
    }

    private func checkForUpdates() async {
        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }
        await loader.checkForUpdatesNow()
    }

    // MARK: - Formatters

    private func formatTokens(_ n: Int) -> String {
        let v = Double(n)
        switch abs(v) {
        case 1_000_000...:
            return String(format: "%.1fM", v / 1_000_000)
        case 1_000...:
            return String(format: "%.0fK", v / 1_000)
        default:
            return "\(n)"
        }
    }

    private func formatDollars(_ d: Double) -> String {
        String(format: "$%.2f", d)
    }

    private func formatPercent(_ p: Double) -> String {
        String(format: "%.0f%%", p * 100)
    }

    private func hitRateColor(_ p: Double) -> Color {
        switch p {
        case 0.7...: return .green
        case 0.3...: return .primary
        default: return .orange
        }
    }

    private func shortDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}

/// Bridge: the per-bucket dollar split needs per-model token counts,
/// but `monthlyTokenBreakdown` on the snapshot has already been
/// aggregated across models. We re-derive it from the disk cache
/// here so the Cost tab doesn't trigger another JSONL scan and so
/// we don't widen `UsageSnapshot` with provider-specific detail.
@MainActor
enum ClaudeMonthlyTokens {
    static func tokensByModel(for provider: (any UsageProvider)?) -> UsageByModel {
        guard let provider, provider.kind == .claude else { return [:] }
        guard let payload = ClaudeCostCache.read() else { return [:] }
        var byModel = UsageByModel()
        for (model, counts) in payload.tokensByModel {
            byModel[model] = TokenUsage(
                input: counts.input,
                output: counts.output,
                cacheWrite: counts.cacheWrite,
                cacheRead: counts.cacheRead,
                cachedInput: counts.cachedInput
            )
        }
        return byModel
    }
}
