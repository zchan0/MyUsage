import Foundation

/// Shell command helpers for process discovery (Antigravity).
enum ProcessHelper {

    /// Run a shell command and return stdout — runs off main thread.
    /// Reads pipe data before waitUntilExit to avoid pipe buffer deadlock.
    static func run(_ command: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", command]

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }

                // Read ALL data BEFORE waitUntilExit — prevents pipe buffer deadlock
                // when stdout exceeds 64KB (e.g. `ps -axww`).
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                continuation.resume(returning: String(data: data, encoding: .utf8))
            }
        }
    }

    /// Find Antigravity language server process.
    /// Returns (pid, csrfToken, extensionServerPort) if found.
    static func findAntigravityProcess() async -> (pid: Int, csrfToken: String, httpPort: Int?)? {
        guard let output = await run("ps -axww -o pid=,command=") else { return nil }

        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Match language_server_macos with antigravity markers
            guard trimmed.contains("language_server_macos") || trimmed.contains("language_server"),
                  trimmed.contains("antigravity") else {
                continue
            }

            // Extract PID
            let parts = trimmed.split(separator: " ", maxSplits: 1)
            guard let pidStr = parts.first, let pid = Int(pidStr) else { continue }

            // Extract CSRF token
            guard let csrfToken = extractFlag(from: trimmed, flag: "--csrf_token") else { continue }

            // Extract extension_server_port (optional)
            let httpPort = extractFlag(from: trimmed, flag: "--extension_server_port").flatMap(Int.init)

            return (pid, csrfToken, httpPort)
        }

        return nil
    }

    /// Find listening TCP ports for a given PID.
    static func findListeningPorts(pid: Int) async -> [Int] {
        guard let output = await run("lsof -nP -iTCP -sTCP:LISTEN -a -p \(pid)") else { return [] }

        var ports: [Int] = []
        for line in output.components(separatedBy: "\n") {
            // Look for lines with ":PORT (LISTEN)"
            guard line.contains("LISTEN") else { continue }
            // Extract port from the "name" column, e.g., "127.0.0.1:12345"
            if let colonRange = line.range(of: ":", options: .backwards),
               let portEnd = line[colonRange.upperBound...].split(separator: " ").first,
               let port = Int(portEnd) {
                ports.append(port)
            }
        }

        return ports.sorted()
    }

    // MARK: - Helpers

    private static func extractFlag(from line: String, flag: String) -> String? {
        guard let range = line.range(of: flag) else { return nil }
        let afterFlag = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return afterFlag.split(separator: " ").first.map(String.init)
    }
}
