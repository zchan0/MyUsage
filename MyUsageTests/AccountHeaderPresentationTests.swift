import Testing
@testable import MyUsage

@Suite("AccountHeaderPresentation")
struct AccountHeaderPresentationTests {

    @Test("Keeps short plan tier badges concise without repeating provider names")
    func shortTierBadge() {
        let claude = AccountHeaderPresentation.make(kind: .claude, rawPlan: "Pro", email: "alex@example.com")
        #expect(claude == .init(email: "alex@example.com", planBadge: "Pro", planFullName: "Pro", fallbackTitle: "Claude"))

        let codex = AccountHeaderPresentation.make(kind: .codex, rawPlan: "Plus", email: "alex@example.com")
        #expect(codex == .init(email: "alex@example.com", planBadge: "Plus", planFullName: "Plus", fallbackTitle: "Codex"))

        let cursor = AccountHeaderPresentation.make(kind: .cursor, rawPlan: "Ultra", email: "alex@example.com")
        #expect(cursor == .init(email: "alex@example.com", planBadge: "Ultra", planFullName: "Ultra", fallbackTitle: "Cursor"))
    }

    @Test("Compacts Google AI tier names into short corner badges while keeping full tooltip text")
    func compactsGoogleAITierNames() {
        let ultra = AccountHeaderPresentation.make(
            kind: .antigravity,
            rawPlan: "Google AI Ultra",
            email: "alexandra.developer@example.com"
        )
        #expect(ultra == .init(
            email: "alexandra.developer@example.com",
            planBadge: "Ultra",
            planFullName: "Google AI Ultra",
            fallbackTitle: "Antigravity"
        ))

        let pro = AccountHeaderPresentation.make(
            kind: .antigravity,
            rawPlan: "Google AI Pro",
            email: "alex@example.com"
        )
        #expect(pro == .init(
            email: "alex@example.com",
            planBadge: "Pro",
            planFullName: "Google AI Pro",
            fallbackTitle: "Antigravity"
        ))
    }

    @Test("Strips duplicate leading provider name from plan badge")
    func stripsDuplicateProviderPrefix() {
        let versioned = AccountHeaderPresentation.make(kind: .antigravity, rawPlan: "Antigravity 2.35.1", email: nil)
        #expect(versioned == .init(email: nil, planBadge: "2.35.1", planFullName: "Antigravity 2.35.1", fallbackTitle: "Antigravity"))

        let prefixed = AccountHeaderPresentation.make(kind: .claude, rawPlan: "claude Max", email: "alex@example.com")
        #expect(prefixed == .init(email: "alex@example.com", planBadge: "Max", planFullName: "claude Max", fallbackTitle: "Claude"))

        let exactDuplicate = AccountHeaderPresentation.make(kind: .claude, rawPlan: "Claude", email: "alex@example.com")
        #expect(exactDuplicate == .init(email: "alex@example.com", planBadge: nil, planFullName: nil, fallbackTitle: "Claude"))
    }

    @Test("Trims whitespace and drops blank email or plan values")
    func trimsBlankValues() {
        let model = AccountHeaderPresentation.make(kind: .codex, rawPlan: "  \n ", email: "  alex@example.com  ")
        #expect(model == .init(email: "alex@example.com", planBadge: nil, planFullName: nil, fallbackTitle: "Codex"))

        let blankEmail = AccountHeaderPresentation.make(kind: .cursor, rawPlan: " Pro ", email: "   ")
        #expect(blankEmail == .init(email: nil, planBadge: "Pro", planFullName: "Pro", fallbackTitle: "Cursor"))
    }
}
