import Foundation
import Testing
@testable import MyUsage

@Suite("Claude statusline snapshots")
struct ClaudeStatuslineSnapshotTests {
    @Test func roundTripAllowlistAndPermissions() throws {
        let f = try ClaudeStatuslineFixture()
        defer { f.cleanup() }
        try f.store.write(f.input(), now: f.now)
        let read = try f.store.read()
        let receipt = try #require(read.latest)
        #expect(!read.hasInvalidFiles)
        #expect(receipt.rateLimits.fiveHour?.usedPercentage == 23.5)
        #expect(receipt.rateLimits.sevenDay?.resetsAt == 1_800_500_000)
        let files = try FileManager.default.contentsOfDirectory(at: f.store.snapshotsDirectory, includingPropertiesForKeys: nil)
        let file = try #require(files.first { $0.pathExtension == "json" })
        let text = try String(contentsOf: file, encoding: .utf8)
        for value in ["do-not-save", "cwd", "transcript_path", "token", "message"] { #expect(!text.contains(value)) }
        let keys = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(Set(keys.keys) == ["schemaVersion", "receivedAt", "sessionID", "claudeCodeVersion", "rateLimits"])
        for url in [f.directory, f.store.snapshotsDirectory] + files {
            let mode = try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
            #expect(mode == (url.pathExtension == "json" || url.pathExtension == "lock" ? 0o600 : 0o700))
        }
    }

    @Test func missingCorruptAndUnsupportedSchema() throws {
        let f = try ClaudeStatuslineFixture()
        defer { f.cleanup() }
        #expect(try f.store.read().latest == nil)
        try f.store.write(f.input(), now: f.now)
        let file = try #require(FileManager.default.contentsOfDirectory(at: f.store.snapshotsDirectory, includingPropertiesForKeys: nil).first { $0.pathExtension == "json" })
        let good = try Data(contentsOf: file)
        for data in [Data(), Data("{".utf8), Data(String(decoding: good, as: UTF8.self).replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":9").utf8)] {
            try ClaudePrivateFiles.atomicWrite(data, to: file)
            #expect(try f.store.read().latest == nil)
            #expect(try f.store.read().hasInvalidFiles)
        }
    }

    @Test func partialAbsentAndInvalidWindows() throws {
        let f = try ClaudeStatuslineFixture()
        defer { f.cleanup() }
        for raw in ["", "\"five_hour\":null", "\"five_hour\":{\"used_percentage\":101,\"resets_at\":1800003600}", "\"five_hour\":{\"used_percentage\":-1,\"resets_at\":1800003600}", "\"five_hour\":{\"used_percentage\":50}", "\"five_hour\":{\"used_percentage\":true,\"resets_at\":1800003600}"] {
            let value = try ClaudeStatuslineSnapshot.capture(f.input(limits: raw), receivedAt: f.now)
            #expect(value.rateLimits.fiveHour == nil)
            #expect(value.rateLimits.sevenDay == nil)
        }
        #expect(throws: (any Error).self) { try f.store.write(Data("{}".utf8), now: f.now) }
        #expect(throws: (any Error).self) { try f.store.write(Data("broken".utf8), now: f.now) }
        #expect(throws: (any Error).self) { try f.store.write(Data(repeating: 32, count: 1_048_577), now: f.now) }
    }

    @Test func concurrentSessionsAndOutOfOrderWriters() async throws {
        let f = try ClaudeStatuslineFixture()
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
        let files = try FileManager.default.contentsOfDirectory(at: f.store.snapshotsDirectory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        #expect(files.count == 8)
        for file in files {
            let value = try JSONDecoder().decode(ClaudeStatuslineSnapshot.self, from: ClaudePrivateFiles.read(file))
            #expect(value.receivedAt >= f.now.timeIntervalSince1970 + 72)
        }
        #expect(try f.store.read().latest?.sessionID == "session-7")
        // Latest incomplete session is authoritative; do not borrow windows from another session.
        try f.store.write(f.input(session: "new-empty-session", limits: ""), now: f.now.addingTimeInterval(100))
        #expect(try f.store.read().latest?.rateLimits.fiveHour == nil)
    }

    @Test func rejectsRedirectedDirectoriesAndWorldReadableFiles() throws {
        let f = try ClaudeStatuslineFixture()
        defer { f.cleanup() }
        try f.store.write(f.input(), now: f.now)
        let file = try #require(FileManager.default.contentsOfDirectory(at: f.store.snapshotsDirectory, includingPropertiesForKeys: nil).first { $0.pathExtension == "json" })
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
