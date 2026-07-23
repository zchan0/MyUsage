import Foundation

/// Pure selection logic for the priority-led Overview. The UI presents one
/// capacity window as the focus; this type makes that choice deterministic and
/// testable instead of relying on view order.
enum CapacityFocus {
    struct Metric: Identifiable, Sendable, Equatable {
        enum PaceStatus: Sendable, Equatable {
            case onTrack
            case aheadOfPace(multiplier: Double)
            case projectedOvershoot(percent: Double)
        }

        let providerKind: ProviderKind
        let label: String
        let percentUsed: Double
        let resetsAt: Date?
        let pacePercent: Double?
        let projectedFinalPercent: Double?

        var id: String { "\(providerKind.rawValue):\(label)" }

        /// One capacity verdict shared by Detail, Overview, and ordering.
        ///
        /// The projection deliberately stays quiet for the first 20% of a
        /// rolling window. During that gate, a large and sustained lead over
        /// the deterministic pace marker is still enough evidence to warn.
        /// Both an absolute lead and a minimum amount consumed are required so
        /// a single prompt at the very start of a window does not false-alarm.
        var paceStatus: PaceStatus {
            if let projectedFinalPercent, projectedFinalPercent > 100 {
                return .projectedOvershoot(percent: projectedFinalPercent)
            }

            guard projectedFinalPercent == nil,
                  let pacePercent,
                  pacePercent > 0,
                  percentUsed >= 20,
                  percentUsed - pacePercent >= 10
            else {
                return .onTrack
            }

            let multiplier = percentUsed / pacePercent
            guard multiplier >= 1.5 else { return .onTrack }
            return .aheadOfPace(multiplier: multiplier)
        }

        var hasCapacityRisk: Bool {
            switch paceStatus {
            case .onTrack:
                false
            case .aheadOfPace, .projectedOvershoot:
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
            switch paceStatus {
            case .onTrack:
                return current
            case .projectedOvershoot(let projected):
                // A reliable projected overshoot should outrank a merely busy
                // window without turning 300% projections into an unbounded
                // visual scale.
                return max(current, 80 + min(projected - 100, 100) * 0.2)
            case .aheadOfPace(let multiplier):
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
                        projectedFinalPercent: $0.projectedFinalPercent(now: now)
                    )
                },
                snapshot.weeklyUsage.map {
                    Metric(
                        providerKind: providerKind,
                        label: "Weekly",
                        percentUsed: $0.percentUsed,
                        resetsAt: $0.resetsAt,
                        pacePercent: $0.onPacePercent(now: now),
                        projectedFinalPercent: $0.projectedFinalPercent(now: now)
                    )
                }
            ].compactMap { $0 }

        case .cursor:
            return [
                snapshot.totalUsagePercent.map {
                    Metric(
                        providerKind: providerKind,
                        label: "Included",
                        percentUsed: $0,
                        resetsAt: snapshot.billingCycleEnd,
                        pacePercent: nil,
                        projectedFinalPercent: nil
                    )
                },
                snapshot.onDemandUsagePercent.map {
                    Metric(
                        providerKind: providerKind,
                        label: "On-demand",
                        percentUsed: $0,
                        resetsAt: snapshot.billingCycleEnd,
                        pacePercent: nil,
                        projectedFinalPercent: nil
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
                    projectedFinalPercent: nil
                )
            }
            .sorted { $0.percentUsed > $1.percentUsed }
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
