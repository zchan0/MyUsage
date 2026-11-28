import AppKit
import SwiftUI

struct BuiltinProviderDeck: View {
    let provider: any BuiltinUsageProvider

    @Environment(\.colorScheme) private var colorScheme
    private var palette: PopoverPalette { PopoverPalette(colorScheme) }
    private var usesRollingLimits: Bool { provider.kind == .claude || provider.kind == .codex }

    var body: some View {
        VStack(spacing: 9) {
            if let snapshot = provider.snapshot {
                quotaSheet(snapshot)
                if let report = snapshot.localUsage {
                    ProviderUsageInstrument(report: report)
                }
            } else {
                GlassSheet {
                    if provider.isLoading {
                        stateRow("Loading…", loading: true)
                    } else if let error = provider.error {
                        stateRow(error, icon: "exclamationmark.triangle", warning: true)
                    } else {
                        stateRow("Not configured", icon: "questionmark.circle")
                    }
                }
            }
        }
        .padding(.horizontal, PopoverLayout.horizontalPadding)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private func quotaSheet(_ snapshot: UsageSnapshot) -> some View {
        let metrics = CapacityFocus.metrics(providerKind: provider.kind, snapshot: snapshot)
        let credits = snapshot.resetCredits.flatMap { $0.reportedAvailableCount > 0 ? $0 : nil }
        let antigravity = provider as? AntigravityProvider
        let isAntigravityStatusline = antigravity?.quotaSource == .statusline
        return GlassSheet {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 11) {
                    accountHeader(snapshot, metrics: metrics)
                    if usesRollingLimits {
                        rollingLimits(metrics)
                    } else if let antigravity, isAntigravityStatusline, snapshot.modelQuotas.isEmpty {
                        antigravityStatuslineEmptyState(antigravity)
                    } else if provider.kind == .antigravity, snapshot.modelQuotas.isEmpty, let issue = provider.error {
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Live quota unavailable")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(palette.inkSecondary)
                                Text(issue)
                                    .font(.system(size: 10))
                                    .foregroundStyle(palette.inkTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 4)
                            if antigravity != nil {
                                settingsPillButton(help: "Open Settings → Providers to connect Antigravity CLI statusline")
                            }
                        }
                    } else {
                        ProviderQuotaInstruments(kind: provider.kind, snapshot: snapshot)
                    }
                }
                .padding(.horizontal, 15)
                .padding(.top, 14)
                .padding(.bottom, credits == nil ? 14 : 12)

                if let credits {
                    ResetCreditsSection(inventory: credits)
                }

                if provider.kind != .claude,
                   !(provider.kind == .antigravity && (snapshot.modelQuotas.isEmpty || isAntigravityStatusline)),
                   let error = provider.error {
                    PopoverHairline()
                    stateRow(error, icon: "exclamationmark.triangle", warning: true)
                }
            }
        }
    }

    private func accountHeader(_ snapshot: UsageSnapshot, metrics: [CapacityFocus.Metric]) -> some View {
        let claude = provider as? ClaudeProvider
        let antigravity = provider as? AntigravityProvider
        let header = AccountHeaderPresentation.make(
            kind: provider.kind,
            rawPlan: claude?.localAccount?.planName ?? snapshot.planName,
            email: claude?.localAccount?.email ?? snapshot.email
        )
        return HStack(alignment: .center, spacing: 5.5) {
            if let email = header.email {
                Text(email)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.inkSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.88)
                    .truncationMode(.middle)
                    .help(claude?.localAccount?.helpText ?? email)
            } else if header.planBadge == nil {
                Text(header.fallbackTitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(palette.inkSecondary)
                    .lineLimit(1)
            }

            if let planBadge = header.planBadge {
                planPill(planBadge, help: header.planFullName ?? planBadge)
                    .fixedSize()
            }

            statuslineWarningIndicator(claude: claude, antigravity: antigravity)

            Spacer(minLength: 4)

            runwayBadge(snapshot, metrics: metrics)
                .fixedSize()
        }
    }

    @ViewBuilder
    private func statuslineWarningIndicator(claude: ClaudeProvider?, antigravity: AntigravityProvider?) -> some View {
        if let claude, claude.dataState == .stale || claude.dataState == .invalid {
            StatuslineDataIndicator(state: claude.dataState)
                .help(claude.sourceMessage)
        } else if let antigravity,
                  antigravity.quotaSource == .statusline,
                  antigravity.statuslineDataState == .stale || antigravity.statuslineDataState == .invalid {
            StatuslineDataIndicator(state: antigravity.statuslineDataState)
                .help(antigravity.statuslineSourceMessage)
        }
    }

    private func planPill(_ text: String, help: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(palette.inkSecondary)
            .lineLimit(1)
            .padding(.horizontal, 5.5)
            .padding(.vertical, 1.5)
            .background(palette.neutralPillBackground, in: Capsule())
            .overlay(Capsule().strokeBorder(palette.neutralPillEdge, lineWidth: 0.5))
            .help(help)
    }

    @ViewBuilder
    private func runwayBadge(_ snapshot: UsageSnapshot, metrics: [CapacityFocus.Metric]) -> some View {
        if provider.kind == .cursor {
            if snapshot.spentAmount != nil || snapshot.onDemandSpend != nil {
                let amount = (snapshot.spentAmount?.amount ?? 0) + (snapshot.onDemandSpend?.amount ?? 0)
                Text(String(format: "$%.2f this cycle", amount))
                    .font(.system(size: 10.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(palette.inkSecondary)
            }
        } else if !metrics.isEmpty {
            if metrics.contains(where: { $0.percentUsed >= LimitSafety.critThreshold }) {
                badge("Near limit", ink: palette.critInk, background: palette.critPillBackground)
            } else if let soonest = metrics.compactMap(\.projectedExhaustionAt).min() {
                let countdown = OverviewSummary.shortCountdown(until: soonest)
                badge("Runs out in \(countdown)", ink: palette.warnInk, background: palette.warnPillBackground)
            } else if metrics.contains(where: \.hasCapacityRisk) {
                badge("Over pace", ink: palette.warnInk, background: palette.warnPillBackground)
            } else {
                Text("Plenty of runway")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(palette.okInk)
            }
        }
    }

    private func badge(_ text: String, ink: Color, background: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(background, in: Capsule())
    }

    @ViewBuilder
    private func rollingLimits(_ metrics: [CapacityFocus.Metric]) -> some View {
        if metrics.isEmpty {
            let claude = provider as? ClaudeProvider
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(claude?.stateLabel ?? "No rolling limits reported")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.inkSecondary)
                    if let hint = claudeStateHint(for: claude) {
                        Text(hint)
                            .font(.system(size: 10))
                            .foregroundStyle(palette.inkTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
                if claude?.dataState == .notConnected || claude?.dataState == .invalid {
                    settingsPillButton(help: "Open Settings → Providers to connect Claude Code statusline")
                }
            }
            .help(claude?.sourceMessage ?? "No rolling limits reported")
        } else {
            VStack(alignment: .leading, spacing: 11) {
                ForEach(metrics) { metric in
                    let isSession = metric.label == "5-hour"
                    let isWeekly = metric.label == "Weekly"
                    let window = UsageWindow(percentUsed: metric.percentUsed, resetsAt: metric.resetsAt)
                    QuotaRunwayRow(
                        win: isSession ? "5h" : isWeekly ? "7d" : metric.label,
                        percent: metric.percentUsed,
                        wide: !isSession && !isWeekly,
                        pacePercent: metric.pacePercent,
                        reset: window.resetCountdown.map { $0 == "Resetting…" ? $0 : "resets \($0)" },
                        verdict: metric.runwayBalance,
                        risk: metric.hasCapacityRisk,
                        detailSummary: CapacityPaceText.detailSummary(for: metric)
                    )
                }
            }
        }
    }

    private func antigravityStatuslineEmptyState(_ antigravity: AntigravityProvider) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(antigravity.statuslineStateLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.inkSecondary)
                if let hint = antigravityStatuslineHint(for: antigravity) {
                    Text(hint)
                        .font(.system(size: 10))
                        .foregroundStyle(palette.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            if antigravity.statuslineDataState == .notConnected || antigravity.statuslineDataState == .invalid {
                settingsPillButton(help: "Open Settings → Providers to connect Antigravity CLI statusline")
            }
        }
        .help(antigravity.statuslineSourceMessage)
    }

    private func antigravityStatuslineHint(for antigravity: AntigravityProvider) -> String? {
        switch antigravity.statuslineDataState {
        case .notConnected:
            return "Enable Antigravity CLI statusline in Settings → Providers."
        case .waiting:
            return "Quota appears after an Antigravity CLI (agy) statusLine update."
        case .stale:
            return "Latest local snapshot is outdated; run a turn in Antigravity CLI (agy) to refresh."
        case .invalid:
            return "Check Settings → Providers for local statusline details."
        case .valid:
            return nil
        }
    }

    private func settingsPillButton(help: String) -> some View {
        SettingsLink {
            Text("Settings")
                .font(.system(size: 10.5, weight: .medium))
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .simultaneousGesture(TapGesture().onEnded {
            SettingsWindowActivator.bringToFront()
        })
        .help(help)
    }

    private func claudeStateHint(for claude: ClaudeProvider?) -> String? {
        guard let claude else { return nil }
        switch claude.dataState {
        case .notConnected:
            return "Enable statusline integration in Settings → Providers."
        case .waiting:
            return "Quota appears after your next Claude Code response."
        case .stale:
            return "Latest local snapshot is outdated; send a message in Claude Code to refresh."
        case .invalid:
            return "Check Settings → Providers for local statusline details."
        case .valid:
            return nil
        }
    }

    private func stateRow(_ text: String, icon: String? = nil, warning: Bool = false, loading: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if loading {
                ProgressView().controlSize(.small)
            } else if let icon {
                Image(systemName: icon)
                    .foregroundStyle(warning ? palette.warnInk : palette.inkSecondary)
            }
            Text(text)
                .foregroundStyle(palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if !loading {
                HStack(spacing: 8) {
                    if let antigravity = provider as? AntigravityProvider, antigravity.quotaSource == .none {
                        settingsPillButton(help: "Open Settings → Providers to connect Antigravity CLI statusline")
                    }
                    Button("Retry") {
                        Task { await provider.refresh(trigger: .manual) }
                    }
                    .buttonStyle(.plain)
                    .fontWeight(.medium)
                    .foregroundStyle(palette.inkPrimary)
                    .disabled(provider.isLoading)
                }
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 15)
        .padding(.vertical, 14)
    }
}
enum AccountHeaderPresentation {
    struct Model: Equatable, Sendable {
        let email: String?
        let planBadge: String?
        let planFullName: String?
        let fallbackTitle: String
    }

    static func normalizedEmail(_ rawEmail: String?) -> String? {
        guard let trimmed = rawEmail?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    static func make(kind: ProviderKind, rawPlan: String?, email rawEmail: String?) -> Model {
        let trimmedPlan = rawPlan?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fullPlan = trimmedPlan.flatMap { $0.isEmpty ? nil : $0 }
        let badge = compactPlanBadge(providerName: kind.shortName, rawPlan: fullPlan)
        return Model(
            email: normalizedEmail(rawEmail),
            planBadge: badge,
            planFullName: badge != nil ? fullPlan : nil,
            fallbackTitle: kind.shortName
        )
    }

    static func compactPlanBadge(providerName: String, rawPlan: String?) -> String? {
        guard let trimmed = rawPlan?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        if trimmed.compare(providerName, options: .caseInsensitive) == .orderedSame {
            return nil
        }
        for prefix in [providerName + " ", "Google AI "] {
            if trimmed.count > prefix.count,
               trimmed.prefix(prefix.count).compare(prefix, options: .caseInsensitive) == .orderedSame {
                let remainder = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
                return remainder.isEmpty ? nil : remainder
            }
        }
        return trimmed
    }
}

enum TokenCountFormatter {
    static func string(_ value: Int) -> String {
        let count = Double(max(0, value))
        switch count {
        case 1_000_000_000...: return compact(count / 1_000_000_000, suffix: "B")
        case 1_000_000...: return compact(count / 1_000_000, suffix: "M")
        case 1_000...: return compact(count / 1_000, suffix: "K")
        default: return String(Int(count))
        }
    }

    private static func compact(_ value: Double, suffix: String) -> String {
        let digits = value >= 100 ? 0 : 1
        return String(format: "%.*f%@", digits, value, suffix)
    }
}

#if DEBUG
#Preview("Account header · Long email & tiers") {
    let now = Date.now
    var claude = UsageSnapshot()
    claude.planName = "Pro"
    claude.email = "alexandra.developer@example.com"
    claude.sessionUsage = UsageWindow(percentUsed: 12, resetsAt: now.addingTimeInterval(4.5 * 3600), windowDuration: 5 * 3600)
    claude.weeklyUsage = UsageWindow(percentUsed: 18, resetsAt: now.addingTimeInterval(6 * 86_400), windowDuration: 7 * 86_400)

    var antigravity = UsageSnapshot()
    antigravity.planName = "Google AI Ultra"
    antigravity.email = "alexandra.developer@example.com"
    antigravity.modelQuotas = [
        ModelQuota(
            label: "Gemini Models · 7d",
            remainingFraction: 0.96,
            resetsAt: now.addingTimeInterval(5 * 86_400),
            groupName: "Gemini Models",
            windowLabel: "7d",
            windowDuration: 7 * 86_400,
            bucketId: "gemini-weekly"
        )
    ]

    var noEmail = UsageSnapshot()
    noEmail.planName = "Plus"
    noEmail.sessionUsage = UsageWindow(percentUsed: 24, resetsAt: now.addingTimeInterval(3 * 3600), windowDuration: 5 * 3600)

    return VStack(spacing: 4) {
        BuiltinProviderDeck(provider: PreviewUsageProvider(kind: .claude, snapshot: claude))
        BuiltinProviderDeck(provider: PreviewUsageProvider(kind: .antigravity, snapshot: antigravity))
        BuiltinProviderDeck(provider: PreviewUsageProvider(kind: .codex, snapshot: noEmail))
    }
    .frame(width: PopoverLayout.width)
    .background { PopoverGlassSurface() }
}
#endif
