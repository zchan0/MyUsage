import Foundation
import Testing
@testable import MyUsage

@Suite("Claude statusline integration")
struct ClaudeStatuslineBridgeTests {
    @Test func preservesBytesOutputExitAndOtherSettings() throws {
        let f = try ClaudeStatuslineFixture()
        defer { f.cleanup() }
        let original = "/bin/cat; printf 'old stderr' >&2; exit 17"
        try f.writeSettings(["statusLine": ["type": "command", "command": original, "padding": 3],
                             "model": "synthetic-model", "permissions": ["allow": ["Read"]]])
        try f.bridge.enable()
        let once = try Data(contentsOf: f.settings)
        try f.bridge.enable()
        #expect(try Data(contentsOf: f.settings) == once)
        let settings = try f.readSettings()
        #expect(settings["model"] as? String == "synthetic-model")
        #expect((settings["permissions"] as? [String: [String]])?["allow"] == ["Read"])
        #expect((settings["statusLine"] as? [String: Any])?["padding"] as? Int == 3)
        var input = f.input()
        input.append(Data("\n\n\n".utf8))
        let result = try f.run(f.command(), input: input)
        #expect(result.output == input)
        #expect(result.error == Data("old stderr".utf8))
        #expect(result.status == 17)
        #expect(try f.store.read().latest?.sessionID == "synthetic-session")
        try f.bridge.disable()
        #expect(try f.command() == original)
        let disabled = try Data(contentsOf: f.settings)
        try f.bridge.disable()
        #expect(try Data(contentsOf: f.settings) == disabled)
        #expect(try f.store.read().latest != nil)
    }

    @Test func failureNeverBreaksOriginalCommand() throws {
        let f = try ClaudeStatuslineFixture()
        defer { f.cleanup() }
        let missingHelper = ClaudeStatuslineBridge(settingsURL: f.settings, directory: f.directory,
                                                   executableURL: f.root.appendingPathComponent("missing executable"))
        // Both an unavailable helper and a valid helper with bad input leave the original command working.
        for bridge in [missingHelper, f.bridge] {
            let command = bridge.makeCommand(original: "/bin/cat; printf ' visible' ; exit 9")
            let input = Data("not JSON \"quotes\" $HOME `literal`\n\n".utf8)
            let result = try f.run(command, input: input)
            #expect(result.output == input + Data(" visible".utf8))
            #expect(result.error.isEmpty)
            #expect(result.status == 9)
        }
        // Simulate an unwritable store without depending on effective-root permissions.
        try FileManager.default.createDirectory(at: f.directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("occupied".utf8).write(to: f.directory)
        let result = try f.run(f.bridge.makeCommand(original: "/bin/cat"), input: f.input())
        #expect(result.output == f.input())
        #expect(result.status == 0)
    }

    @Test func absentStatuslineAndEmptyOutput() throws {
        let f = try ClaudeStatuslineFixture()
        defer { f.cleanup() }
        try f.writeSettings(["theme": "synthetic"])
        try f.bridge.enable()
        let result = try f.run(f.command(), input: f.input())
        #expect(result.output.isEmpty)
        #expect(result.error.isEmpty)
        #expect(result.status == 0)
        try f.bridge.disable()
        #expect(try f.readSettings()["statusLine"] == nil)
        #expect(try f.readSettings()["theme"] as? String == "synthetic")
    }

    @Test func collectorReadsMultiplePipeChunksWithoutPersistingInput() throws {
        let f = try ClaudeStatuslineFixture()
        defer { f.cleanup() }
        let raw = try #require(JSONSerialization.jsonObject(with: f.input()) as? [String: Any])
        var large = raw
        large["message"] = String(repeating: "synthetic-ignored-content ", count: 12_000)
        let input = try JSONSerialization.data(withJSONObject: large)
        #expect(input.count > 65_536)
        let result = try f.run(f.bridge.makeCommand(original: "printf 'original'"), input: input)
        #expect(result.output == Data("original".utf8))
        #expect(result.status == 0)
        #expect(try f.store.read().latest?.sessionID == "synthetic-session")
        let file = try #require(FileManager.default.contentsOfDirectory(at: f.store.snapshotsDirectory, includingPropertiesForKeys: nil).first { $0.pathExtension == "json" })
        #expect(try Data(contentsOf: file).count < 1024)
    }

    @Test func userEditsSurviveDisableAndConflictsDoNotReinstall() throws {
        let f = try ClaudeStatuslineFixture()
        defer { f.cleanup() }
        try f.writeSettings(["statusLine": ["type": "command", "command": "echo original", "padding": 1]])
        try f.bridge.enable()
        var object = try f.readSettings()
        var line = object["statusLine"] as! [String: Any]
        line["padding"] = 8
        line["refreshInterval"] = 2000
        object["statusLine"] = line
        object["theme"] = "new-theme"
        try f.writeSettings(object)
        try f.bridge.disable()
        #expect(try f.command() == "echo original")
        #expect((try f.readSettings()["statusLine"] as? [String: Any])?["padding"] as? Int == 8)
        #expect((try f.readSettings()["statusLine"] as? [String: Any])?["refreshInterval"] as? Int == 2000)
        #expect(try f.readSettings()["theme"] as? String == "new-theme")
        try f.bridge.enable()
        try f.writeSettings(["statusLine": ["type": "command", "command": "echo user's new command"], "theme": "latest"])
        let before = try Data(contentsOf: f.settings)
        #expect(throws: (any Error).self) { try f.bridge.disable() }
        #expect(throws: (any Error).self) { try f.bridge.enable() }
        #expect(try Data(contentsOf: f.settings) == before)
        #expect(!f.bridge.isInstalled)
    }

    @Test func newStatuslineFieldsAndManualRemovalSurvive() throws {
        let f = try ClaudeStatuslineFixture()
        defer { f.cleanup() }
        try f.bridge.enable()
        var settings = try f.readSettings()
        var line = settings["statusLine"] as! [String: Any]
        line["padding"] = 9
        settings["statusLine"] = line
        try f.writeSettings(settings)
        try f.bridge.disable()
        #expect((try f.readSettings()["statusLine"] as? [String: Int]) == ["padding": 9])
        // A user deleting the wrapper must not resurrect an old command.
        try f.writeSettings(["statusLine": ["type": "command", "command": "echo original"]])
        try f.bridge.enable()
        try f.writeSettings(["theme": "user-removed-statusline"])
        let before = try Data(contentsOf: f.settings)
        #expect(throws: (any Error).self) { try f.bridge.disable() }
        #expect(try Data(contentsOf: f.settings) == before)
    }

    @Test func malformedSettingsAndUnsupportedCommandsAreUntouched() throws {
        let f = try ClaudeStatuslineFixture()
        defer { f.cleanup() }
        for raw in ["{", "{\"statusLine\":\"custom\"}", "{\"statusLine\":{\"type\":\"other\",\"command\":\"hello\"}}"] {
            let data = Data(raw.utf8)
            try data.write(to: f.settings)
            #expect(throws: (any Error).self) { try f.bridge.enable() }
            #expect(try Data(contentsOf: f.settings) == data)
        }
    }

    @Test func processesCanWriteConcurrentlyAndQuotePaths() async throws {
        let f = try ClaudeStatuslineFixture()
        defer { f.cleanup() }
        let quotedDirectory = f.root.appendingPathComponent("spaces and 'quotes' $(do-not-run)")
        let bridge = ClaudeStatuslineBridge(settingsURL: f.settings, directory: quotedDirectory, executableURL: f.executable)
        let command = bridge.makeCommand(original: "printf '%s' \"old 'quoted' output\"")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<12 {
                group.addTask {
                    let result = try f.run(command, input: f.input(session: "process-\(i)"))
                    #expect(result.output == Data("old 'quoted' output".utf8))
                    #expect(result.status == 0)
                }
            }
            try await group.waitForAll()
        }
        let store = ClaudeStatuslineStore(directory: quotedDirectory)
        let files = try FileManager.default.contentsOfDirectory(at: store.snapshotsDirectory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        #expect(files.count == 12)
        #expect(try !store.read().hasInvalidFiles)
    }
}
