import Foundation
import Testing
@testable import MyUsage

@Suite("Antigravity statusline snapshots")
struct AntigravityStatuslineSnapshotTests {
    @Test func roundTripAllowlistAndPermissions() throws {
        let f = try AntigravityStatuslineFixture()
        defer { f.cleanup() }
        try f.store.write(f.input(), now: f.now)
        let read = try f.store.read()
        let receipt = try #require(read.latest)
        #expect(!read.hasInvalidFiles)
        #expect(receipt.sessionID == "synthetic-conv")
        #expect(receipt.cliVersion == "2.35.synthetic")
        #expect(receipt.planTier == "Google AI Ultra")
        #expect(receipt.email == "synthetic@example.com")
        #expect(receipt.quotas.count == 4)
        #expect(receipt.quotas.first { $0.bucketID == "gemini-5h" }?.remainingFraction == 0.765)
        #expect(receipt.quotas.first { $0.bucketID == "3p-weekly" }?.resetsAt == 1_800_500_000)

        let files = try FileManager.default.contentsOfDirectory(
            at: f.store.snapshotsDirectory,
            includingPropertiesForKeys: nil
        )
        let file = try #require(files.first { $0.pathExtension == "json" })
        let text = try String(contentsOf: file, encoding: .utf8)
        for forbidden in ["do-not-save", "cwd", "transcript_path", "token", "message"] {
            #expect(!text.contains(forbidden))
        }
        let keys = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(Set(keys.keys) == ["schemaVersion", "receivedAt", "sessionID", "cliVersion", "planTier", "email", "quotas"])
        for url in [f.directory, f.store.snapshotsDirectory] + files {
            let mode = try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
            #expect(mode == (url.pathExtension == "json" || url.pathExtension == "lock" ? 0o600 : 0o700))
        }
    }

    @Test func parsesGroupedNestedArrayAndResetVariants() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let grouped = Data("""
        {
            "session_id": "grouped-session",
            "version": "2.35.1",
            "account": {"plan_tier": "Google AI Pro", "email": "dev@example.com"},
            "quota": {
                "groups": [
                    {
                        "display_name": "Gemini Models",
                        "buckets": [
                            {"bucket_id": "gemini-5h", "remaining_fraction": 0.6, "reset_in_seconds": 3600},
                            {"bucket_id": "gemini-weekly", "used_fraction": 0.25, "reset_time": "2027-01-20T12:00:00.500Z"},
                            {"bucket_id": "gemini-full", "remaining_percentage": 100, "reset_in_seconds": 0},
                            {"bucket_id": "disabled-one", "remaining_fraction": 0.5, "disabled": true},
                            {"bucket_id": "bad-bool", "remaining_fraction": true},
                            {"bucket_id": "bad-range", "remaining_fraction": 1.5}
                        ]
                    },
                    {
                        "displayName": "Claude & GPT Models",
                        "quotaBuckets": [
                            {"id": "3p-weekly", "used_percentage": 40, "resets_at": 1800500000000}
                        ]
                    }
                ]
            }
        }
        """.utf8)
        let groupedSnap = try AntigravityStatuslineSnapshot.capture(grouped, receivedAt: now)
        #expect(groupedSnap.sessionID == "grouped-session")
        #expect(groupedSnap.planTier == "Google AI Pro")
        #expect(groupedSnap.email == "dev@example.com")
        #expect(groupedSnap.quotas.count == 4)
        #expect(groupedSnap.quotas[0].groupName == "Gemini Models")
        #expect(groupedSnap.quotas[0].remainingFraction == 0.6)
        #expect(groupedSnap.quotas[0].resetsAt == now.timeIntervalSince1970 + 3600)
        #expect(abs(groupedSnap.quotas[1].remainingFraction - 0.75) < 0.0001)
        #expect(groupedSnap.quotas[2].bucketID == "gemini-full")
        // reset_in_seconds == 0 must yield nil rather than an already-expired timestamp.
        #expect(groupedSnap.quotas[2].resetsAt == nil)
        #expect(groupedSnap.quotas[3].groupName == "Claude & GPT Models")
        #expect(abs(groupedSnap.quotas[3].remainingFraction - 0.6) < 0.0001)
        #expect(groupedSnap.quotas[3].resetsAt == 1_800_500_000)

        let nestedDict = Data("""
        {"version":"2.35.1","quota":{"buckets":{"gemini-5h":{"remaining_fraction":0.8}}}}
        """.utf8)
        let nestedSnap = try AntigravityStatuslineSnapshot.capture(nestedDict, receivedAt: now)
        #expect(nestedSnap.sessionID == "default")
        #expect(nestedSnap.quotas.map(\.bucketID) == ["gemini-5h"])

        let bucketArray = Data("""
        {"version":"2.35.1","quota":{"buckets":[{"bucket_id":"gemini-5h","remaining_fraction":0.7}]}}
        """.utf8)
        #expect(try AntigravityStatuslineSnapshot.capture(bucketArray, receivedAt: now).quotas.map(\.bucketID) == ["gemini-5h"])

        let topArray = Data("""
        {"version":"2.35.1","quota":[{"id":"3p-5h","remaining_fraction":0.9}]}
        """.utf8)
        #expect(try AntigravityStatuslineSnapshot.capture(topArray, receivedAt: now).quotas.map(\.bucketID) == ["3p-5h"])
    }

    @Test func capsBucketsAndSanitizesEmail() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let entries = (0..<40).map { #""bucket-\#(String(format: "%02d", $0))":{"remaining_fraction":0.5}"# }.joined(separator: ",")
        let raw = Data(#"{"conversation_id":"s","email":"not an email","quota":{\#(entries)}}"#.utf8)
        let snapshot = try AntigravityStatuslineSnapshot.capture(raw, receivedAt: now)
        #expect(snapshot.email == nil)
        #expect(snapshot.quotas.count == 32)
    }

    @Test func missingCorruptOversizedAndUnsupportedSchema() throws {
        let f = try AntigravityStatuslineFixture()
        defer { f.cleanup() }
        #expect(try f.store.read().latest == nil)
        #expect(try !f.store.read().hasInvalidFiles)

        try f.store.write(f.input(), now: f.now)
        let file = try #require(FileManager.default.contentsOfDirectory(
            at: f.store.snapshotsDirectory,
            includingPropertiesForKeys: nil
        ).first { $0.pathExtension == "json" })
        let good = try Data(contentsOf: file)
        for data in [
            Data(),
            Data("{".utf8),
            Data(String(decoding: good, as: UTF8.self).replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":9").utf8)
        ] {
            try ClaudePrivateFiles.atomicWrite(data, to: file)
            #expect(try f.store.read().latest == nil)
            #expect(try f.store.read().hasInvalidFiles)
        }

        #expect(throws: (any Error).self) { try f.store.write(Data("{}".utf8), now: f.now) }
        #expect(throws: (any Error).self) { try f.store.write(Data("{\"unrelated\":1}".utf8), now: f.now) }
        #expect(throws: (any Error).self) { try f.store.write(Data("broken".utf8), now: f.now) }
        #expect(throws: (any Error).self) { try f.store.write(Data(repeating: 32, count: 1_048_577), now: f.now) }
    }

    @Test func concurrentSessionsAndOutOfOrderWriters() async throws {
        let f = try AntigravityStatuslineFixture()
        defer { f.cleanup() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<80 {
                group.addTask {
                    try f.store.write(f.input(session: "session-\(i % 8)"), now: f.now.addingTimeInterval(Double(i)))
                    let read = try f.store.read()
                    #expect(!read.hasInvalidFiles)
                }
            }
            try await group.waitForAll()
        }
        let files = try FileManager.default.contentsOfDirectory(
            at: f.store.snapshotsDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        #expect(files.count == 8)
        for file in files {
            let value = try JSONDecoder().decode(AntigravityStatuslineSnapshot.self, from: ClaudePrivateFiles.read(file))
            #expect(value.receivedAt >= f.now.timeIntervalSince1970 + 72)
        }
        #expect(try f.store.read().latest?.sessionID == "session-7")
        // Latest incomplete session is authoritative; do not borrow buckets from an older session.
        try f.store.write(f.input(session: "new-empty-session", quota: ""), now: f.now.addingTimeInterval(100))
        #expect(try f.store.read().latest?.quotas.isEmpty == true)
    }

    @Test func rejectsRedirectedDirectoriesAndWorldReadableFiles() throws {
        let f = try AntigravityStatuslineFixture()
        defer { f.cleanup() }
        try f.store.write(f.input(), now: f.now)
        let file = try #require(FileManager.default.contentsOfDirectory(
            at: f.store.snapshotsDirectory,
            includingPropertiesForKeys: nil
        ).first { $0.pathExtension == "json" })
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(try f.store.read().hasInvalidFiles)

        try FileManager.default.removeItem(at: f.store.snapshotsDirectory)
        let other = f.root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.store.snapshotsDirectory, withDestinationURL: other)
        #expect(throws: (any Error).self) { try f.store.read() }
        #expect(throws: (any Error).self) { try f.store.write(f.input(), now: f.now) }
    }
}
