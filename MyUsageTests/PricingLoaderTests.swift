import Testing
import Foundation
@testable import MyUsage

/// Coverage of the bits of the spec-16 pricing pipeline that don't
/// need a network round-trip. The remote fetch itself is exercised
/// manually via the spec's verification checklist.
///
/// We deliberately do NOT mutate `PricingCatalog.shared` here:
/// swift-testing runs suites in parallel, and the LedgerParser
/// suite reads `PricingCatalog.shared` directly, so any global
/// swap would race with its expectations. The atomicity of the
/// shared store is covered implicitly by `OSAllocatedUnfairLock`
/// itself.
@MainActor
@Suite("PricingLoader & PricingCatalog sharing")
struct PricingLoaderTests {

    // MARK: - FetchOutcome short-circuits

    @Test("Fetcher skips when auto-update is disabled")
    func fetcherSkipsWhenDisabled() async {
        let loader = PricingLoader.shared
        let priorToggle = loader.autoUpdatePricing
        loader.autoUpdatePricing = false
        defer { loader.autoUpdatePricing = priorToggle }

        let outcome = await PricingRemoteFetcher.shared.fetch(force: true)
        if case .skippedDisabled = outcome {
            // ok
        } else {
            Issue.record("Expected .skippedDisabled, got \(outcome)")
        }
    }

    // MARK: - PricingLoader bundled fallback

    @Test("Loader initially exposes a non-empty bundled catalog")
    func bundledLoadsByDefault() {
        // Bundled pricing.json must be findable on test launch — if
        // this fails the resource isn't reaching the test target and
        // every cost number silently goes to $0.
        #expect(PricingCatalog.shared.modelCount > 0)
        #expect(PricingCatalog.shared.pricing(for: "claude-sonnet-4-5") != nil)
        #expect(PricingCatalog.shared.pricing(for: "gpt-5-codex") != nil)
    }
}
