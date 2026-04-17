import Testing
import Foundation
@testable import MyUsage

@Suite("CursorProvider Tests")
struct CursorProviderTests {

    // MARK: - Usage Response Parsing

    @Test("Parse full usage response")
    func parseUsageResponse() throws {
        let json = """
        {
            "billingCycleStart": "1768399334000",
            "billingCycleEnd": "1771077734000",
            "planUsage": {
                "totalSpend": 23222,
                "includedSpend": 23222,
                "remaining": 16778,
                "limit": 40000,
                "autoPercentUsed": 0,
                "apiPercentUsed": 46.444,
                "totalPercentUsed": 15.48
            },
            "spendLimitUsage": {
                "totalSpend": 0,
                "individualLimit": 10000,
                "individualUsed": 0,
                "individualRemaining": 10000,
                "limitType": "user"
            }
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(CursorUsageResponse.self, from: data)

        #expect(response.planUsage?.totalPercentUsed == 15.48)
        #expect(response.planUsage?.totalSpend == 23222)
        #expect(response.planUsage?.limit == 40000)
        #expect(response.spendLimitUsage?.individualLimit == 10000)
        #expect(response.billingCycleEnd == "1771077734000")
    }

    @Test("Parse plan info response")
    func parsePlanInfo() throws {
        let json = """
        {
            "planInfo": {
                "planName": "Ultra",
                "includedAmountCents": 40000,
                "price": "$200/mo",
                "billingCycleEnd": "1771077734000"
            }
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(CursorPlanInfoResponse.self, from: data)

        #expect(response.planInfo?.planName == "Ultra")
        #expect(response.planInfo?.includedAmountCents == 40000)
        #expect(response.planInfo?.price == "$200/mo")
    }

    // MARK: - Snapshot Mapping

    @Test("Map usage with included budget under limit")
    func mapSnapshotUnderLimit() {
        // Ultra plan, spent $232.22 out of $400 budget
        let usage = CursorUsageResponse(
            billingCycleStart: "1768399334000",
            billingCycleEnd: "1771077734000",
            planUsage: .init(
                totalSpend: 23222, includedSpend: 23222,
                remaining: 16778, limit: 40000,
                autoPercentUsed: 12.0, apiPercentUsed: 34.0,
                totalPercentUsed: 46.0
            ),
            spendLimitUsage: .init(
                totalSpend: 0, individualLimit: 10000,
                individualUsed: 0, individualRemaining: 10000,
                pooledLimit: nil, pooledUsed: nil,
                limitType: "user"
            )
        )
        let plan = CursorPlanInfoResponse(
            planInfo: .init(planName: "Ultra", includedAmountCents: 40000, price: "$200/mo", billingCycleEnd: "1771077734000")
        )

        let snapshot = CursorProvider.mapToSnapshot(usage: usage, plan: plan, email: "test@email.com", membership: nil)

        #expect(snapshot.planName == "Ultra")
        #expect(snapshot.email == "test@email.com")
        // Included: $232.22 / $400.00 = 58.055%
        #expect(snapshot.spentAmount?.amount == 232.22)
        #expect(snapshot.spentAmount?.limit == 400.0)
        #expect(snapshot.totalUsagePercent != nil)
        #expect(snapshot.totalUsagePercent! > 50)
        // No on-demand yet (under budget)
        #expect(snapshot.onDemandSpend == nil)
        #expect(snapshot.billingCycleEnd != nil)
    }

    @Test("Map usage exceeding included budget")
    func mapSnapshotOverBudget() {
        // Team plan ($20 budget), included exhausted, $5 on-demand
        let usage = CursorUsageResponse(
            billingCycleStart: nil, billingCycleEnd: nil,
            planUsage: .init(
                totalSpend: 2500, includedSpend: 2000,
                remaining: 0, limit: 2000,
                autoPercentUsed: nil, apiPercentUsed: nil,
                totalPercentUsed: nil
            ),
            spendLimitUsage: .init(
                totalSpend: 500, individualLimit: 5000,
                individualUsed: 500, individualRemaining: 4500,
                pooledLimit: nil, pooledUsed: nil,
                limitType: "user"
            )
        )

        let snapshot = CursorProvider.mapToSnapshot(usage: usage, plan: nil, email: nil, membership: "team")

        #expect(snapshot.planName == "Team")
        // Included: $20/$20 = 100%
        #expect(snapshot.spentAmount?.amount == 20.0)
        #expect(snapshot.spentAmount?.limit == 20.0)
        #expect(snapshot.totalUsagePercent == 100)
        // On-demand: $5 (from spendLimitUsage.individualUsed)
        #expect(snapshot.onDemandSpend != nil)
        #expect(snapshot.onDemandSpend?.amount == 5.0)
        #expect(snapshot.onDemandSpend?.limit == 50.0)
    }

    @Test("Map without plan info, uses membership fallback")
    func mapSnapshotMembershipFallback() {
        let usage = CursorUsageResponse(
            billingCycleStart: nil, billingCycleEnd: nil,
            planUsage: .init(
                totalSpend: 500, includedSpend: nil,
                remaining: nil, limit: nil,
                autoPercentUsed: nil, apiPercentUsed: nil,
                totalPercentUsed: nil
            ),
            spendLimitUsage: nil
        )
        let snapshot = CursorProvider.mapToSnapshot(usage: usage, plan: nil, email: nil, membership: "pro")

        #expect(snapshot.planName == "Pro")
        // Pro budget = $20, spent $5 = 25%
        #expect(snapshot.spentAmount?.amount == 5.0)
        #expect(snapshot.totalUsagePercent == 25.0)
    }

    @Test("Map with zero spend")
    func mapZeroSpend() {
        let usage = CursorUsageResponse(
            billingCycleStart: nil, billingCycleEnd: nil,
            planUsage: .init(
                totalSpend: 0, includedSpend: nil,
                remaining: nil, limit: nil,
                autoPercentUsed: nil, apiPercentUsed: nil,
                totalPercentUsed: nil
            ),
            spendLimitUsage: nil
        )
        let snapshot = CursorProvider.mapToSnapshot(usage: usage, plan: nil, email: nil, membership: "pro")

        #expect(snapshot.totalUsagePercent == 0)
        #expect(snapshot.spentAmount?.amount == 0)
        #expect(snapshot.onDemandSpend == nil)
    }

    @Test("Monthly cost = included + on-demand")
    func monthlyCostIncludedPlusOnDemand() {
        // Team plan ($20 budget), included exhausted, $5 on-demand
        let usage = CursorUsageResponse(
            billingCycleStart: nil, billingCycleEnd: nil,
            planUsage: .init(
                totalSpend: 2500, includedSpend: 2000,
                remaining: 0, limit: 2000,
                autoPercentUsed: nil, apiPercentUsed: nil,
                totalPercentUsed: nil
            ),
            spendLimitUsage: .init(
                totalSpend: 500, individualLimit: 5000,
                individualUsed: 500, individualRemaining: 4500,
                pooledLimit: nil, pooledUsed: nil,
                limitType: "user"
            )
        )
        let snapshot = CursorProvider.mapToSnapshot(usage: usage, plan: nil, email: nil, membership: "team")
        #expect(snapshot.monthlyEstimatedCost == 25.0) // 20 + 5
    }

    @Test("Monthly cost nil when zero spend")
    func monthlyCostNilWhenZero() {
        let usage = CursorUsageResponse(
            billingCycleStart: nil, billingCycleEnd: nil,
            planUsage: .init(
                totalSpend: 0, includedSpend: nil,
                remaining: nil, limit: nil,
                autoPercentUsed: nil, apiPercentUsed: nil,
                totalPercentUsed: nil
            ),
            spendLimitUsage: nil
        )
        let snapshot = CursorProvider.mapToSnapshot(usage: usage, plan: nil, email: nil, membership: "pro")
        #expect(snapshot.monthlyEstimatedCost == nil)
    }

    @Test("Billing cycle date from unix ms string")
    func billingCycleDate() {
        let usage = CursorUsageResponse(
            billingCycleStart: nil,
            billingCycleEnd: "1771077734000",
            planUsage: nil,
            spendLimitUsage: nil
        )
        let snapshot = CursorProvider.mapToSnapshot(usage: usage, plan: nil, email: nil, membership: nil)

        #expect(snapshot.billingCycleEnd != nil)
        // 1771077734000 ms = 1771077734 seconds
        let expected = Date(timeIntervalSince1970: 1771077734)
        #expect(snapshot.billingCycleEnd == expected)
    }
}
