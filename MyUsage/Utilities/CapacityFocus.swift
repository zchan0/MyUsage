import Foundation

/// Pure selection logic for the priority-led Overview. The UI presents one
/// capacity window as the focus; this type makes that choice deterministic and
/// testable instead of relying on view order.
enum CapacityFocus {
    struct Metric: Identifiable, Sendable, Equatable {
        enum PaceBalance: Sendable, Equatable {
            case onPace
            case deficit(percent: Double)
            case reserve(percent: Double)
        }

        enum RiskSignal: Sendable, Equatable {
            case none
            case earlyDeficit(multiplier: Double)
            case projectedOvershoot(percent: Double)
        }

        enum PaceOutcome: Sendable, Equatable {
            case runsOut(at: Date)
            case lastsUntilReset
        }

        let providerKind: ProviderKind
        let label: String
        let percentUsed: Double
        let resetsAt: Date?
        let pacePercent: Double?
        let projectedFinalPercent: Double?
        let projectedExhaustionAt: Date?

        var id: String { "\(providerKind.rawValue):\(label)" }

        /// Distance from the deterministic pace notch, expressed in
        /// percentage points. A ±2-point dead zone matches the visual reading
        /// of the bar: tiny fill/marker differences are simply "On pace."
        var paceBalance: PaceBalance? {
            guard let pacePercent else { return nil }
            let delta = percentUsed - pacePercent
            if abs(delta) <= 2 { return .onPace }
            if delta > 0 { return .deficit(percent: delta) }
            return .reserve(percent: abs(delta))
        }

        /// Actionable outcome is intentionally separate from pace balance.
        /// It appears only after the projection reliability gate has opened.
        var paceOutcome: PaceOutcome? {
            if let projectedExhaustionAt {
                return .runsOut(at: projectedExhaustionAt)
            }
            if projectedFinalPercent != nil {
                return .lastsUntilReset
            }
            return nil
        }

        /// One risk verdict shared by Detail, Overview, and ordering. The
        /// early-window fallback stays internal; users see the more legible
        /// reserve/deficit distance instead of a burn-rate multiplier.
        var riskSignal: RiskSignal {
            if let projectedFinalPercent, projectedFinalPercent > 100 {
                return .projectedOvershoot(percent: projectedFinalPercent)
            }

            guard projectedFinalPercent == nil,
                  let pacePercent,
                  pacePercent > 0,
                  percentUsed >= 20,
                  percentUsed - pacePercent >= 10
            else {
                return .none
            }

            let multiplier = percentUsed / pacePercent
            guard multiplier >= 1.5 else { return .none }
            return .earlyDeficit(multiplier: multiplier)
        }

        var hasCapacityRisk: Bool {
            switch riskSignal {
            case .none:
                false
            case .earlyDeficit, .projectedOvershoot:
                true
            }
        }

        var needsAttention: Bool {
            percentUsed >= 75 || hasCapacityRisk
        }

        /// Overview uses a higher static-percent threshold than Detail so a
        /// long billing cycle does not look urgent merely for being busy.
        /// Pace-based risk is shared, including the early-window fallback.
        var requiresOverviewAttention: Bool {
            percentUsed >= 90 || hasCapacityRisk
        }

        var riskScore: Double {
            let current = percentUsed
            switch riskSignal {
            case .none:
                return current
            case .projectedOvershoot(let projected):
                // A reliable projected overshoot should outrank a merely busy
                // window without turning 300% projections into an unbounded
                // visual scale.
                return max(current, 80 + min(projected - 100, 100) * 0.2)
            case .earlyDeficit(let multiplier):
                // Early-window evidence is intentionally capped at the same
                // ceiling as a reliable projection.
                return max(current, 80 + min(multiplier - 1, 1) * 20)
            }
        }
    }

    static func metrics(
        providerKind: ProviderKind,
        snapshot: UsageSnapshot,
        now: Date = .now
    ) -> [Metric] {
        switch providerKind {
        case .claude, .codex:
            return [
                snapshot.sessionUsage.map {
                    Metric(
                        providerKind: providerKind,
                        label: "5-hour",
                        percentUsed: $0.percentUsed,
                        resetsAt: $0.resetsAt,
                        pacePercent: $0.onPacePercent(now: now),
                        projectedFinalPercent: $0.projectedFinalPercent(now: now),
                        projectedExhaustionAt: $0.projectedExhaustionDate(now: now)
                    )
                },
                snapshot.weeklyUsage.map {
                    Metric(
                        providerKind: providerKind,
                        label: "Weekly",
                        percentUsed: $0.percentUsed,
                        resetsAt: $0.resetsAt,
                        pacePercent: $0.onPacePercent(now: now),
                        projectedFinalPercent: $0.projectedFinalPercent(now: now),
                        projectedExhaustionAt: $0.projectedExhaustionDate(now: now)
                    )
                }
            ].compactMap { $0 } + scopedModelMetrics(
                providerKind: providerKind,
                snapshot: snapshot,
                now: now
            )

        case .cursor:
            return [
                snapshot.totalUsagePercent.map {
                    Metric(
                        providerKind: providerKind,
                        label: "Included",
                        percentUsed: $0,
                        resetsAt: snapshot.billingCycleEnd,
                        pacePercent: nil,
                        projectedFinalPercent: nil,
                        projectedExhaustionAt: nil
                    )
                },
                snapshot.onDemandUsagePercent.map {
                    Metric(
                        providerKind: providerKind,
                        label: "On-demand",
                        percentUsed: $0,
                        resetsAt: snapshot.billingCycleEnd,
                        pacePercent: nil,
                        projectedFinalPercent: nil,
                        projectedExhaustionAt: nil
                    )
                }
            ].compactMap { $0 }

        case .antigravity:
            return snapshot.modelQuotas.map {
                Metric(
                    providerKind: providerKind,
                    label: $0.label,
                    percentUsed: $0.percentUsed,
                    resetsAt: $0.resetsAt,
                    pacePercent: nil,
                    projectedFinalPercent: nil,
                    projectedExhaustionAt: nil
                )
            }
            .sorted { $0.percentUsed > $1.percentUsed }
        }
    }

    /// Model-scoped weekly caps (Claude's `weekly_scoped` limits — Fable, Opus,
    /// …) are real quotas with their own reset, so they are first-class rolling
    /// limits, not a footnote: a Fable cap at 98% is the binding constraint even
    /// when the pooled weekly bar reads 40%, and Overview has to be able to
    /// focus on it. Product caps (Daily Routines, OAuth apps) stay out — they
    /// are not what "how much capacity do I have left" means.
    ///
    /// Empty for every plan that pools its quota, and for every provider other
    /// than Claude, so the ordinary case pays nothing.
    private static func scopedModelMetrics(
        providerKind: ProviderKind,
        snapshot: UsageSnapshot,
        now: Date
    ) -> [Metric] {
        snapshot.weeklyByModel
            .filter { $0.scope == .model }
            .map { row in
                let window = UsageWindow(
                    percentUsed: row.percent,
                    resetsAt: row.resetsAt,
                    windowDuration: 7 * 24 * 3600
                )
                return Metric(
                    providerKind: providerKind,
                    // CodexBar's wording: the cap that applies to this model
                    // only, as opposed to the pooled weekly bar above it.
                    label: "\(row.label) only",
                    percentUsed: row.percent,
                    resetsAt: row.resetsAt,
                    pacePercent: window.onPacePercent(now: now),
                    projectedFinalPercent: window.projectedFinalPercent(now: now),
                    projectedExhaustionAt: window.projectedExhaustionDate(now: now)
                )
            }
    }

    static func select(from metrics: [Metric], now: Date = .now) -> Metric? {
        let attention = metrics.filter(\.needsAttention)
        if !attention.isEmpty {
            return attention.max { lhs, rhs in
                if lhs.riskScore != rhs.riskScore { return lhs.riskScore < rhs.riskScore }
                return futureReset(lhs.resetsAt, now: now) > futureReset(rhs.resetsAt, now: now)
            }
        }

        let upcoming = metrics.filter { $0.resetsAt.map { $0 > now } == true }
        if !upcoming.isEmpty {
            return upcoming.min { lhs, rhs in
                futureReset(lhs.resetsAt, now: now) < futureReset(rhs.resetsAt, now: now)
            }
        }

        return metrics.max { $0.percentUsed < $1.percentUsed }
    }

    private static func futureReset(_ date: Date?, now: Date) -> Date {
        guard let date, date > now else { return .distantFuture }
        return date
    }
}

enum CapacityPaceText {
    static func balanceLabel(for metric: CapacityFocus.Metric) -> String? {
        guard let balance = metric.paceBalance else { return nil }
        switch balance {
        case .onPace:
            return "On pace"
        case .deficit(let percent):
            return "\(Int(percent.rounded()))% in deficit"
        case .reserve(let percent):
            return "\(Int(percent.rounded()))% in reserve"
        }
    }

    static func outcomeLabel(
        for metric: CapacityFocus.Metric,
        now: Date = .now
    ) -> String? {
        guard let outcome = metric.paceOutcome else { return nil }
        switch outcome {
        case .runsOut(let date):
            return "Runs out in \(OverviewSummary.shortCountdown(until: date, now: now))"
        case .lastsUntilReset:
            return "Lasts until reset"
        }
    }

    static func detailSummary(
        for metric: CapacityFocus.Metric,
        now: Date = .now
    ) -> String? {
        [balanceLabel(for: metric), outcomeLabel(for: metric, now: now)]
            .compactMap { $0 }
            .joined(separator: " · ")
            .nilIfEmpty
    }

    static func overviewSummary(
        for metric: CapacityFocus.Metric,
        now: Date = .now
    ) -> String? {
        guard let balance = compactBalanceLabel(for: metric) else { return nil }
        guard case .runsOut(let date) = metric.paceOutcome else { return balance }
        let countdown = OverviewSummary.shortCountdown(until: date, now: now)
        return "\(balance) · runs out in \(countdown)"
    }

    private static func compactBalanceLabel(for metric: CapacityFocus.Metric) -> String? {
        guard let balance = metric.paceBalance else { return nil }
        switch balance {
        case .onPace:
            return "On pace"
        case .deficit(let percent):
            return "\(Int(percent.rounded()))% deficit"
        case .reserve(let percent):
            return "\(Int(percent.rounded()))% reserve"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
