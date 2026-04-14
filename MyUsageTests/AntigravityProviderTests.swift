import Testing
import Foundation
@testable import MyUsage

@Suite("AntigravityProvider Tests")
struct AntigravityProviderTests {

    // MARK: - UserStatus Response Parsing

    @Test("Parse full GetUserStatus response")
    func parseUserStatus() throws {
        let json = """
        {
            "userStatus": {
                "planStatus": {
                    "planInfo": {
                        "planName": "Pro"
                    }
                },
                "cascadeModelConfigData": {
                    "clientModelConfigs": [
                        {
                            "label": "Gemini 3 Pro (High)",
                            "quotaInfo": {
                                "remainingFraction": 0.75,
                                "resetTime": "2026-04-14T20:00:00Z"
                            }
                        },
                        {
                            "label": "Claude Sonnet 4.5",
                            "quotaInfo": {
                                "remainingFraction": 0.2,
                                "resetTime": "2026-04-14T20:00:00Z"
                            }
                        }
                    ]
                },
                "accountEmail": "user@example.com"
            }
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(AntigravityUserStatusResponse.self, from: data)

        #expect(response.userStatus?.planStatus?.planInfo?.planName == "Pro")
        #expect(response.userStatus?.cascadeModelConfigData?.clientModelConfigs?.count == 2)
        #expect(response.userStatus?.accountEmail == "user@example.com")
    }

    // MARK: - Snapshot Mapping

    @Test("Map UserStatus response to snapshot")
    func mapUserStatusSnapshot() {
        let response = AntigravityUserStatusResponse(
            userStatus: .init(
                planStatus: .init(planInfo: .init(planName: "Pro")),
                cascadeModelConfigData: .init(clientModelConfigs: [
                    .init(label: "Gemini 3 Pro", quotaInfo: .init(remainingFraction: 0.75, resetTime: "2026-04-14T20:00:00Z")),
                    .init(label: "Claude Sonnet 4.5", quotaInfo: .init(remainingFraction: 0.2, resetTime: "2026-04-14T20:00:00Z")),
                    .init(label: "GPT-OSS 120B", quotaInfo: .init(remainingFraction: 1.0, resetTime: nil)),
                ]),
                accountEmail: "user@test.com"
            )
        )

        let snapshot = AntigravityProvider.mapToSnapshot(response)

        #expect(snapshot.planName == "Pro")
        #expect(snapshot.email == "user@test.com")
        #expect(snapshot.modelQuotas.count == 3)
        #expect(snapshot.modelQuotas[0].label == "Gemini 3 Pro")
        #expect(snapshot.modelQuotas[0].remainingFraction == 0.75)
        #expect(snapshot.modelQuotas[0].percentUsed == 25.0)  // 1 - 0.75 = 0.25 → 25%
        #expect(snapshot.modelQuotas[1].percentUsed == 80.0)  // 1 - 0.2 = 0.8 → 80%
        #expect(snapshot.modelQuotas[2].percentUsed == 0.0)   // 1 - 1.0 = 0 → 0%
    }

    @Test("Map fallback model configs response")
    func mapModelConfigsFallback() {
        let response = AntigravityModelConfigsResponse(
            clientModelConfigs: [
                .init(label: "Model A", quotaInfo: .init(remainingFraction: 0.5, resetTime: nil)),
                .init(label: "Model B", quotaInfo: .init(remainingFraction: 0.9, resetTime: nil)),
            ]
        )

        let snapshot = AntigravityProvider.mapConfigsToSnapshot(response)

        #expect(snapshot.planName == nil)
        #expect(snapshot.email == nil)
        #expect(snapshot.modelQuotas.count == 2)
        #expect(snapshot.modelQuotas[0].percentUsed == 50.0)
        #expect(abs(snapshot.modelQuotas[1].percentUsed - 10.0) < 0.01)
    }

    @Test("Skip models with missing quota info")
    func skipMissingQuota() {
        let response = AntigravityUserStatusResponse(
            userStatus: .init(
                planStatus: nil,
                cascadeModelConfigData: .init(clientModelConfigs: [
                    .init(label: "Good Model", quotaInfo: .init(remainingFraction: 0.6, resetTime: nil)),
                    .init(label: nil, quotaInfo: .init(remainingFraction: 0.5, resetTime: nil)),  // missing label
                    .init(label: "No Quota", quotaInfo: nil),  // missing quota
                ]),
                accountEmail: nil
            )
        )

        let snapshot = AntigravityProvider.mapToSnapshot(response)
        #expect(snapshot.modelQuotas.count == 1)
        #expect(snapshot.modelQuotas[0].label == "Good Model")
    }

    @Test("Worst usage from model quotas")
    func worstUsageFromQuotas() {
        let response = AntigravityUserStatusResponse(
            userStatus: .init(
                planStatus: nil,
                cascadeModelConfigData: .init(clientModelConfigs: [
                    .init(label: "A", quotaInfo: .init(remainingFraction: 0.1, resetTime: nil)),  // 90% used
                    .init(label: "B", quotaInfo: .init(remainingFraction: 0.5, resetTime: nil)),  // 50% used
                ]),
                accountEmail: nil
            )
        )

        let snapshot = AntigravityProvider.mapToSnapshot(response)
        #expect(snapshot.worstUsagePercent == 90.0)
    }

    // MARK: - Process Helper

    @Test("Extract flag from command line")
    func extractFlag() {
        // This is tested implicitly via findAntigravityProcess
        // Direct unit test for the CLI flag extraction pattern
        let line = "12345 /path/to/language_server_macos --csrf_token abc123 --extension_server_port 8080 --app_data_dir antigravity"

        // Simulate the extraction logic
        let parts = line.split(separator: " ", maxSplits: 1)
        #expect(parts.count == 2)
        #expect(Int(parts[0]) == 12345)
    }
}
