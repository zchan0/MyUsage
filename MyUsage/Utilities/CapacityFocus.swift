import Foundation

/// Pure selection logic for the priority-led Overview. The UI presents one
/// capacity window as the focus; this type makes that choice deterministic and
/// testable instead of relying on view order.
enum CapacityFocus {
    struct Metric: Identifiable, Sendable, Equatable {
        let providerKind: ProviderKind
        let label: String
        let percentUsed: Double
        let resetsAt: Date?
        let pacePercent: Double?
        let projectedFinalPercent: Double?

        var id: String { "\(providerKind.rawValue):\(label)" }

        var needsAttention: Bool {
            percentUsed >= 75 || (projectedFinalPercent ?? 0) > 100
        }

        var riskScore: Double {
            let current = percentUsed
            guard let projectedFinalPercent, projectedFinalPercent > 100 else { return current }
            // A reliable projected overshoot should outrank a merely busy but
            // still healthy window without turning 300% projections into an
            // unbounded visual scale.
            return max(current, 80 + min(projectedFinalPercent - 100, 100) * 0.2)
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
