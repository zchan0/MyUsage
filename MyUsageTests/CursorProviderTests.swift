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

    @Test("Map usage + plan to snapshot")
    func mapSnapshot() {
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
                individualUsed: 500, individualRemaining: 9500,
                pooledLimit: nil, pooledUsed: nil,
                limitType: "user"
            )
        )
        let plan = CursorPlanInfoResponse(
            planInfo: .init(planName: "Ultra", includedAmountCents: 40000, price: "$200/mo", billingCycleEnd: "1771077734000")
        )

        let snapshot = CursorProvider.mapToSnapshot(usage: usage, plan: plan, email: "test@email.com", membership: nil)

        #expect(snapshot.totalUsagePercent == 46.0)
        #expect(snapshot.autoUsagePercent == 12.0)
        #expect(snapshot.apiUsagePercent == 34.0)
        #expect(snapshot.planName == "Ultra")
        #expect(snapshot.email == "test@email.com")
        #expect(snapshot.spentAmount?.amount == 232.22)  // 23222 cents
        #expect(snapshot.spentAmount?.limit == 400.0)     // 40000 cents
        #expect(snapshot.onDemandSpend?.amount == 5.0)    // 500 cents
        #expect(snapshot.onDemandSpend?.limit == 100.0)   // 10000 cents
        #expect(snapshot.billingCycleEnd != nil)
    }

    @Test("Map without plan info, uses membership fallback")
    func mapSnapshotMembershipFallback() {
        let usage = CursorUsageResponse(
            billingCycleStart: nil, billingCycleEnd: nil,
            planUsage: .init(
                totalSpend: nil, includedSpend: nil,
                remaining: nil, limit: nil,
                autoPercentUsed: nil, apiPercentUsed: nil,
                totalPercentUsed: 20.0
            ),
            spendLimitUsage: nil
        )
        let snapshot = CursorProvider.mapToSnapshot(usage: usage, plan: nil, email: nil, membership: "pro")

        #expect(snapshot.planName == "Pro")
        #expect(snapshot.totalUsagePercent == 20.0)
    }

    @Test("Map without spend limit — no on-demand")
    func mapNoSpendLimit() {
        let usage = CursorUsageResponse(
            billingCycleStart: nil, billingCycleEnd: nil,
            planUsage: .init(
                totalSpend: 1000, includedSpend: 1000,
                remaining: 1000, limit: 2000,
                autoPercentUsed: nil, apiPercentUsed: nil,
                totalPercentUsed: 50.0
            ),
            spendLimitUsage: nil
        )
        let snapshot = CursorProvider.mapToSnapshot(usage: usage, plan: nil, email: nil, membership: nil)

        #expect(snapshot.onDemandSpend == nil)
        #expect(snapshot.spentAmount?.amount == 10.0)
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
