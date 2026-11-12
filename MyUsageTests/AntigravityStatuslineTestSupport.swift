import Foundation
@testable import MyUsage

struct AntigravityStatuslineFixture {
    let root: URL
    let directory: URL
    let settings: URL
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    var store: AntigravityStatuslineStore { .init(directory: directory) }

    var executable: URL {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [
            repo.appendingPathComponent(".build/debug/MyUsage"),
            repo.appendingPathComponent(".build/arm64-apple-macosx/debug/MyUsage"),
            repo.appendingPathComponent(".build/out/Products/Debug/MyUsage"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) } ?? candidates[0]
    }

    var bridge: AntigravityStatuslineBridge {
        .init(settingsURL: settings, directory: directory, executableURL: executable)
    }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("antigravity-statusline-\(UUID())")
        directory = root.appendingPathComponent("Application Support/MyUsage/AntigravityStatusline")
        settings = root.appendingPathComponent("antigravity-cli/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func input(
        session: String = "synthetic-conv",
        version: String = "2.35.synthetic",
        planTier: String? = "Google AI Ultra",
        email: String? = "synthetic@example.com",
        quota: String = """
        "3p-5h":{"remaining_fraction":1.0,"resets_at":1800003600},
        "3p-weekly":{"remaining_fraction":0.59,"resets_at":1800500000},
        "gemini-5h":{"remaining_fraction":0.765,"resets_at":1800003600},
        "gemini-weekly":{"remaining_fraction":0.85,"resets_at":1800500000}
        """
    ) -> Data {
        var extra: [String] = []
        if let planTier { extra.append("\"plan_tier\":\"\(planTier)\"") }
        if let email { extra.append("\"email\":\"\(email)\"") }
        let extraPrefix = extra.isEmpty ? "" : extra.joined(separator: ",") + ","
        return Data("""
        {"conversation_id":"\(session)","version":"\(version)",\(extraPrefix)"quota":{\(quota)},"cwd":"/private/project-do-not-save","transcript_path":"/private/transcript-do-not-save","token":"synthetic-do-not-save","message":"do-not-save"}
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
