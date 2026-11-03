import Foundation
@testable import MyUsage

struct ClaudeStatuslineFixture {
    let root: URL
    let directory: URL
    let settings: URL
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var store: ClaudeStatuslineStore { .init(directory: directory) }
    var executable: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/MyUsage")
    }
    var bridge: ClaudeStatuslineBridge {
        .init(settingsURL: settings, directory: directory, executableURL: executable)
    }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-statusline-\(UUID())")
        directory = root.appendingPathComponent("Application Support/MyUsage/ClaudeStatusline")
        settings = root.appendingPathComponent("claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    func input(session: String = "synthetic-session", limits: String = "\"five_hour\":{\"used_percentage\":23.5,\"resets_at\":1800003600},\"seven_day\":{\"used_percentage\":41.2,\"resets_at\":1800500000}") -> Data {
        Data("""
        {"session_id":"\(session)","version":"2.1.synthetic","rate_limits":{\(limits)},"cwd":"/private/project-do-not-save","transcript_path":"/private/transcript-do-not-save","token":"synthetic-do-not-save","message":"do-not-save"}
        """.utf8)
    }
    func writeSettings(_ object: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: object, options: .sortedKeys).write(to: settings)
    }
    func readSettings() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
    }
    func command() throws -> String {
        (try readSettings()["statusLine"] as! [String: Any])["command"] as! String
    }
    func run(_ command: String, input: Data) throws -> (output: Data, error: Data, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf: input)
        try stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let error = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (output, error, process.terminationStatus)
    }
}
