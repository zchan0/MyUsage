import Foundation
import Testing
@testable import MyUsage

@Suite("ClaudeUsageCache Tests")
struct ClaudeUsageCacheTests {

    // MARK: - Fingerprint

    @Test("Fingerprint is deterministic and 12 lowercase-hex chars")
    func fingerprintDeterministic() {
        let a = ClaudeUsageCache.fingerprint(refreshToken: "abc123")
        let b = ClaudeUsageCache.fingerprint(refreshToken: "abc123")
        #expect(a == b)
        #expect(a.count == 12)
        #expect(a.allSatisfy { $0.isHexDigit })
    }

    @Test("Different refresh tokens yield different fingerprints")
    func fingerprintDifferent() {
        let a = ClaudeUsageCache.fingerprint(refreshToken: "aaa")
        let b = ClaudeUsageCache.fingerprint(refreshToken: "bbb")
        #expect(a != b)
    }

    @Test("Fingerprint of known input matches SHA-256 prefix")
    func fingerprintKnownVector() {
        // SHA-256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
        #expect(ClaudeUsageCache.fingerprint(refreshToken: "abc") == "ba7816bf8f01")
    }

    // MARK: - Round-trip

    @Test("Write then read returns identical payload")
    func roundTrip() throws {
        let url = tempURL()
        defer { cleanup(url) }

        let response = sampleResponse()
        let fetchedAt = Date(timeIntervalSince1970: 1_745_240_000)

        try ClaudeUsageCache.write(
            response: response,
            fingerprint: "deadbeef1234",
            at: fetchedAt,
            to: url
        )

        let payload = try #require(ClaudeUsageCache.read(from: url))
        #expect(payload.v == ClaudeUsageCache.currentVersion)
        #expect(payload.credentialFingerprint == "deadbeef1234")
        #expect(payload.fetchedAt.timeIntervalSince1970 == 1_745_240_000)
        #expect(payload.response.fiveHour?.utilization == 35)
        #expect(payload.response.sevenDay?.utilization == 18)
    }

    // MARK: - Matching filter

    @Test("Matching fingerprint returns payload")
    func matchingFingerprintHit() throws {
        let url = tempURL()
        defer { cleanup(url) }
        try ClaudeUsageCache.write(
            response: sampleResponse(),
            fingerprint: "aaaaaaaaaaaa",
            to: url
        )
        #expect(ClaudeUsageCache.read(from: url, matching: "aaaaaaaaaaaa") != nil)
    }

    @Test("Mismatched fingerprint returns nil")
    func fingerprintMismatch() throws {
        let url = tempURL()
        defer { cleanup(url) }
        try ClaudeUsageCache.write(
            response: sampleResponse(),
            fingerprint: "aaaaaaaaaaaa",
            to: url
        )
        #expect(ClaudeUsageCache.read(from: url, matching: "bbbbbbbbbbbb") == nil)
    }

    // MARK: - Failure modes

    @Test("Missing file returns nil (no throw)")
    func missingFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID()).json")
        #expect(ClaudeUsageCache.read(from: url) == nil)
    }

    @Test("Corrupt JSON returns nil")
    func corruptJSON() throws {
        let url = tempURL()
        defer { cleanup(url) }
        try Data("not json".utf8).write(to: url)
        #expect(ClaudeUsageCache.read(from: url) == nil)
    }

    @Test("Empty file returns nil")
    func emptyFile() throws {
        let url = tempURL()
        defer { cleanup(url) }
        try Data().write(to: url)
        #expect(ClaudeUsageCache.read(from: url) == nil)
    }

    @Test("Unknown schema version returns nil")
    func schemaVersionMismatch() throws {
        let url = tempURL()
        defer { cleanup(url) }
        let future = """
        {
          "v": 99,
          "credentialFingerprint": "aaaaaaaaaaaa",
          "fetchedAt": 1745240000,
          "response": {}
        }
        """
        try Data(future.utf8).write(to: url)
        #expect(ClaudeUsageCache.read(from: url) == nil)
    }

    // MARK: - Directory creation

    @Test("Write creates intermediate directories")
    func createsIntermediateDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-cache-tests-\(UUID())", isDirectory: true)
        let nested = root
            .appendingPathComponent("deeply", isDirectory: true)
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("claude-usage.json")
        defer { try? FileManager.default.removeItem(at: root) }

        try ClaudeUsageCache.write(
            response: sampleResponse(),
            fingerprint: "ff",
            to: nested
        )
        #expect(FileManager.default.fileExists(atPath: nested.path))
    }

    @Test("Repeated writes overwrite atomically")
    func repeatedWrites() throws {
        let url = tempURL()
        defer { cleanup(url) }

        try ClaudeUsageCache.write(
            response: sampleResponse(utilization: 10),
            fingerprint: "f1",
            to: url
        )
        try ClaudeUsageCache.write(
            response: sampleResponse(utilization: 99),
            fingerprint: "f2",
            to: url
        )

        let payload = try #require(ClaudeUsageCache.read(from: url))
        #expect(payload.credentialFingerprint == "f2")
        #expect(payload.response.fiveHour?.utilization == 99)
    }

    // MARK: - Helpers

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-usage-\(UUID()).json")
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func sampleResponse(utilization: Int = 35) -> ClaudeUsageResponse {
        ClaudeUsageResponse(
            fiveHour: .init(utilization: utilization, resetsAt: "2026-04-14T20:00:00Z"),
            sevenDay: .init(utilization: 18, resetsAt: "2026-04-20T00:00:00Z"),
            sevenDayOscar: nil,
            extraUsage: nil
        )
    }
}
