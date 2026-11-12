import SwiftUI

struct ProviderQuotaInstruments: View {
    let kind: ProviderKind
    let snapshot: UsageSnapshot

    var body: some View {
        switch kind {
        case .claude, .codex:
            EmptyView()
        case .cursor:
            CursorLimits(snapshot: snapshot)
        case .antigravity:
            AntigravityLimits(quotas: snapshot.modelQuotas)
        }
    }
}

/// Supports grouped rolling buckets and the legacy flat model list.
struct AntigravityLimits: View {
    let quotas: [ModelQuota]
    @Environment(\.colorScheme) private var colorScheme

    private struct QuotaSection: Identifiable {
        let id: String
        let title: String?
        let items: [ModelQuota]
    }

    var body: some View {
        let palette = PopoverPalette(colorScheme)
        if quotas.isEmpty {
            Text("No model quotas reported")
                .font(.system(size: 11))
                .foregroundStyle(palette.inkSecondary)
        } else {
            let sections = sections
            VStack(alignment: .leading, spacing: 0) {
                ForEach(sections) { section in
                    if section.id != sections.first?.id {
                        PopoverHairline()
                            .padding(.top, 13)
                            .padding(.bottom, 12)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        if let title = section.title {
                            Text(title)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(palette.inkSecondary)
                        }
                        VStack(alignment: .leading, spacing: 11) {
                            ForEach(section.items) { quota in quotaRow(quota) }
                        }
                    }
                }
            }
        }
    }

    private func quotaRow(_ quota: ModelQuota) -> some View {
        let window = quota.usageWindow
        let metric = CapacityFocus.Metric(providerKind: .antigravity, label: quota.label, window: window)
        return QuotaRunwayRow(
            win: quota.windowLabel ?? quota.label,
            percent: quota.percentUsed,
            wide: quota.windowLabel == nil,
            pacePercent: metric.pacePercent,
            reset: window.resetCountdown.map { $0 == "Resetting…" ? $0 : "resets \($0)" },
            verdict: quota.windowLabel == "7d" || metric.hasCapacityRisk ? metric.runwayBalance : nil,
            risk: metric.hasCapacityRisk,
            detailSummary: CapacityPaceText.detailSummary(for: metric)
        )
    }

    private var sections: [QuotaSection] {
        var result: [QuotaSection] = []
        var indexByTitle: [String: Int] = [:]

        for quota in quotas {
            let key = quota.groupName ?? ""
            if let existing = indexByTitle[key] {
                result[existing] = QuotaSection(
                    id: result[existing].id,
                    title: result[existing].title,
                    items: result[existing].items + [quota]
                )
            } else {
                indexByTitle[key] = result.count
                result.append(QuotaSection(
                    id: key.isEmpty ? "ungrouped-\(result.count)" : key,
                    title: quota.groupName,
                    items: [quota]
                ))
            }
        }
        return result
    }
}

struct CursorLimits: View {
    let snapshot: UsageSnapshot
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = PopoverPalette(colorScheme)
        VStack(alignment: .leading, spacing: 11) {
            if let spent = snapshot.spentAmount {
                includedRow(spent)
            }
            if let onDemand = snapshot.onDemandSpend {
                if let percent = snapshot.onDemandUsagePercent {
                    QuotaRunwayRow(win: "On-demand", percent: percent, wide: true, reset: "+\(onDemand.formatted) cap")
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("On-demand")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(palette.inkSecondary)
                        Spacer(minLength: 8)
                        Text("+\(onDemand.formatted)")
                            .font(.system(size: 11.5, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(palette.inkPrimary)
                    }
                }
            }
            if snapshot.spentAmount == nil && snapshot.onDemandSpend == nil {
                Text("No usage limits on this plan")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.inkSecondary)
            }
        }
    }

    private func includedRow(_ spent: CreditInfo) -> some View {
        let percent = snapshot.totalUsagePercent ?? 0
        let end = snapshot.billingCycleEnd
        let duration = snapshot.billingCycleStart.flatMap { start in end.map { $0.timeIntervalSince(start) } }
        let window = UsageWindow(percentUsed: percent, resetsAt: end, windowDuration: duration)
        let metric = CapacityFocus.Metric(providerKind: .cursor, label: "Included", window: window)
        let reset = end.map { " · resets \($0.formatted(.dateTime.month(.abbreviated).day()))" } ?? ""

        return QuotaRunwayRow(
            win: "Included",
            percent: percent,
            wide: true,
            pacePercent: metric.pacePercent,
            reset: spent.formatted + reset,
            verdict: metric.runwayBalance,
            risk: metric.hasCapacityRisk,
            detailSummary: CapacityPaceText.detailSummary(for: metric)
        )
    }
}
