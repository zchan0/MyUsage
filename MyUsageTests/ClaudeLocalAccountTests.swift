import Foundation
import Testing
@testable import MyUsage

@Suite("Claude local account cache")
struct ClaudeLocalAccountTests {
    @Test("Read only cached profile fields; billing method does not establish a plan")
    func cachedProfile() throws {
        let data = Data("""
        {"oauthAccount":{"emailAddress":" alex@example.com ","organizationType":"claude_pro",
        "profileFetchedAt":1800000000000,"billingType":"apple_subscription"},
        "apiKey":"synthetic-do-not-use","projects":{"/private/do-not-save":{}},
        "mcpServers":{"example":{"env":{"SECRET":"synthetic-do-not-use"}}}}
        """.utf8)
        let account = try #require(ClaudeLocalAccount.parse(data))
        #expect(account.email == "alex@example.com")
        #expect(account.planName == "Pro")
        #expect(account.cachedAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(account.helpText.contains("May be outdated"))
        let unknown = ClaudeLocalAccount.parse(Data("""
        {"oauthAccount":{"emailAddress":"alex@example.com","organizationType":"unknown",
        "billingType":"apple_subscription"}}
        """.utf8))
        #expect(unknown?.email == "alex@example.com")
        #expect(unknown?.planName == nil)
    }

    @Test("Missing and malformed caches do not infer an account", arguments: [
        "broken", "{}", "{\"oauthAccount\":null}",
        "{\"oauthAccount\":{\"emailAddress\":\"not-an-email\"}}",
        "{\"oauthAccount\":{\"emailAddress\":\"alex@example.com\\nspoof\"}}",
        "{\"oauthAccount\":{\"emailAddress\":42}}"
    ])
    func invalidProfiles(json: String) {
        #expect(ClaudeLocalAccount.parse(Data(json.utf8)) == nil)
    }

    @Test("Custom config directories do not borrow the default account")
    func configPaths() {
        let home = URL(fileURLWithPath: "/synthetic/home")
        #expect(ClaudeLocalAccount.defaultURL(home: home, environment: [:]).path == "/synthetic/home/.claude.json")
        #expect(ClaudeLocalAccount.defaultURL(home: home, environment: ["CLAUDE_CONFIG_DIR": "/synthetic/work"]).path
                == "/synthetic/work/.claude.json")
    }

    @Test("Reject symlinks, directories, oversized files and absent files without writing")
    func safeReads() throws {
        let f = try ClaudeStatuslineFixture()
        defer { f.cleanup() }
        #expect(ClaudeLocalAccount.read(from: f.accountURL) == nil)
        #expect(!FileManager.default.fileExists(atPath: f.accountURL.path))
        let data = Data("{\"oauthAccount\":{\"emailAddress\":\"alex@example.com\"}}".utf8)
        try data.write(to: f.accountURL)
        #expect(ClaudeLocalAccount.read(from: f.accountURL)?.email == "alex@example.com")
        #expect(try Data(contentsOf: f.accountURL) == data)
        let link = f.root.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.accountURL)
        #expect(ClaudeLocalAccount.read(from: link) == nil)
        #expect(ClaudeLocalAccount.read(from: f.root) == nil)
        try Data(repeating: 32, count: 4 * 1_048_576 + 1).write(to: f.accountURL)
        #expect(ClaudeLocalAccount.read(from: f.accountURL) == nil)
    }

    @Test("Refresh cached display details without changing quota identity or receipt time")
    @MainActor
    func providerRefresh() async throws {
        let f = try ClaudeStatuslineFixture()
        defer { f.cleanup() }
        let now = f.now
        try f.bridge.enable()
        try f.store.write(f.input(), now: now)
        let settingsBefore = try Data(contentsOf: f.settings)
        let provider = ClaudeProvider(directory: f.directory, bridge: f.bridge, logRoots: [],
                                      accountURL: f.accountURL, now: { now })
        #expect(provider.localAccount == nil)
        for (email, trigger) in [("first@example.com", UsageRefreshTrigger.automatic), ("second@example.com", .manual)] {
            try Data("{\"oauthAccount\":{\"emailAddress\":\"\(email)\",\"organizationType\":\"claude_pro\"}}".utf8)
                .write(to: f.accountURL)
            await provider.refresh(trigger: trigger)
            #expect(provider.localAccount?.email == email)
            #expect(provider.localAccount?.planName == "Pro")
            #expect(provider.snapshot?.email == nil)
            #expect(provider.snapshot?.planName == nil)
            #expect(provider.snapshot?.lastRefreshed == now)
            #expect(provider.dataState == .valid)
        }
        try FileManager.default.removeItem(at: f.accountURL)
        await provider.refresh(trigger: .manual)
        #expect(provider.localAccount == nil)
        #expect(provider.snapshot?.sessionUsage?.percentUsed == 23.5)
        #expect(try Data(contentsOf: f.settings) == settingsBefore)
    }
}
