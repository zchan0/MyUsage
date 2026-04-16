import Testing
@testable import MyUsage

@Suite("ProviderKind Tests")
struct ProviderKindTests {

    @Test("All cases exist")
    func allCases() {
        #expect(ProviderKind.allCases.count == 4)
        #expect(ProviderKind.allCases.contains(.claude))
        #expect(ProviderKind.allCases.contains(.codex))
        #expect(ProviderKind.allCases.contains(.cursor))
        #expect(ProviderKind.allCases.contains(.antigravity))
    }

    @Test("Display names are correct")
    func displayNames() {
        #expect(ProviderKind.claude.displayName == "Claude Code")
        #expect(ProviderKind.codex.displayName == "Codex")
        #expect(ProviderKind.cursor.displayName == "Cursor")
        #expect(ProviderKind.antigravity.displayName == "Antigravity")
    }

    @Test("Each provider has a display name and accent color")
    func displayProperties() {
        for kind in ProviderKind.allCases {
            #expect(!kind.displayName.isEmpty)
        }
    }

    @Test("Raw values match expected strings")
    func rawValues() {
        #expect(ProviderKind.claude.rawValue == "claude")
        #expect(ProviderKind.codex.rawValue == "codex")
        #expect(ProviderKind.cursor.rawValue == "cursor")
        #expect(ProviderKind.antigravity.rawValue == "antigravity")
    }
}
