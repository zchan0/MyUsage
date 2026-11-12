import Foundation

/// Discovered Antigravity language server process metadata.
struct AntigravityProcessInfo: Sendable, Equatable {
    let pid: Int
    /// CLI CSRF token when exposed via `--csrf_token`. Nil on Antigravity 2.34+
    /// standalone builds that pass bridge auth privately over stdin.
    let csrfToken: String?
    /// Explicit HTTPS port when passed via `--https_server_port` (> 0).
    let httpsPort: Int?
    /// Explicit HTTP / extension server port when passed (> 0).
    let httpPort: Int?
    /// Reported IDE/app version when passed via `--override_ide_version`.
    let ideVersion: String?
    /// True when the process reads its bridge token from stdin rather than CLI args.
    let usesStdinBridgeToken: Bool

    init(
        pid: Int,
        csrfToken: String?,
        httpsPort: Int? = nil,
        httpPort: Int? = nil,
        ideVersion: String? = nil,
        usesStdinBridgeToken: Bool = false
    ) {
        self.pid = pid
        self.csrfToken = csrfToken
        self.httpsPort = httpsPort
        self.httpPort = httpPort
        self.ideVersion = ideVersion
        self.usesStdinBridgeToken = usesStdinBridgeToken
    }

    var hasCSRFToken: Bool {
        guard let csrfToken else { return false }
        return !csrfToken.isEmpty
    }
}

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

    /// Find all running Antigravity language server processes (desktop 2.0, IDE, or CLI).
    static func findAntigravityProcesses() async -> [AntigravityProcessInfo] {
        guard let output = await run("ps -axww -o pid=,command=") else { return [] }
        return parseAntigravityProcesses(from: output)
    }

    /// Find the first Antigravity language server process.
    static func findAntigravityProcess() async -> AntigravityProcessInfo? {
        await findAntigravityProcesses().first
    }

    /// Pure parser for `ps -axww -o pid=,command=` output.
    /// Matches both legacy IDE (`language_server_macos*` + `--app_data_dir antigravity`)
    /// and Antigravity 2.0 (`Antigravity.app/Contents/Resources/bin/language_server`,
    /// `~/.gemini/antigravity`, `agy` CLI) case-insensitively.
    static func parseAntigravityProcesses(from output: String) -> [AntigravityProcessInfo] {
        var results: [AntigravityProcessInfo] = []

        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            guard trimmed.contains("language_server") else { continue }

            let isAntigravity = trimmed.localizedCaseInsensitiveContains("antigravity")
                || trimmed.contains("/agy/")
                || trimmed.contains("agy-cli")
            guard isAntigravity else { continue }

            // Extract PID
            let parts = trimmed.split(separator: " ", maxSplits: 1)
            guard let pidStr = parts.first, let pid = Int(pidStr) else { continue }

            // Extract optional CSRF token (--csrf_token VALUE or --csrf_token=VALUE).
            // Antigravity 2.34+ desktop standalone servers omit this flag and use
            // `--read_host_bridge_token_from_stdin` instead.
            let rawToken = extractFlag(from: trimmed, flags: ["--csrf_token", "-csrf_token"])
            let csrfToken = (rawToken?.isEmpty == false) ? rawToken : nil
            let ideVersion = extractFlag(from: trimmed, flags: ["--override_ide_version", "-override_ide_version"])
            let usesStdinBridgeToken = trimmed.contains("--read_host_bridge_token_from_stdin")

            // Extract explicit ports (ignore 0, which requests a dynamic OS port)
            let httpsPort = extractPositivePort(
                from: trimmed,
                flags: ["--https_server_port", "-https_server_port"]
            )
            let httpPort = extractPositivePort(
                from: trimmed,
                flags: [
                    "--extension_server_port", "-extension_server_port",
                    "--http_server_port", "-http_server_port"
                ]
            )

            results.append(AntigravityProcessInfo(
                pid: pid,
                csrfToken: csrfToken,
                httpsPort: httpsPort,
                httpPort: httpPort,
                ideVersion: ideVersion,
                usesStdinBridgeToken: usesStdinBridgeToken
            ))
        }

        // Prioritize processes that expose a CLI CSRF token ahead of hardened stdin-only ones.
        return results.sorted { lhs, rhs in
            if lhs.hasCSRFToken != rhs.hasCSRFToken {
                return lhs.hasCSRFToken && !rhs.hasCSRFToken
            }
            return false
        }
    }

    /// Find listening TCP ports for a given PID.
    static func findListeningPorts(pid: Int) async -> [Int] {
        guard let output = await run("lsof -nP -iTCP -sTCP:LISTEN -a -p \(pid)") else { return [] }
        return parseListeningPorts(from: output)
    }

    /// Pure parser for `lsof -nP -iTCP -sTCP:LISTEN` output.
    static func parseListeningPorts(from output: String) -> [Int] {
        var ports = Set<Int>()
        for line in output.components(separatedBy: "\n") {
            guard line.contains("LISTEN") else { continue }
            if let colonRange = line.range(of: ":", options: .backwards),
               let portEnd = line[colonRange.upperBound...].split(separator: " ").first,
               let port = Int(portEnd), port > 0 {
                ports.insert(port)
            }
        }
        return ports.sorted()
    }

    // MARK: - Helpers

    static func extractFlag(from line: String, flags: [String]) -> String? {
        let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
        for (index, token) in tokens.enumerated() {
            for flag in flags {
                if token == flag, index + 1 < tokens.count {
                    let value = tokens[index + 1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    if !value.hasPrefix("-") { return value }
                } else if token.hasPrefix(flag + "=") {
                    let value = String(token.dropFirst(flag.count + 1))
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    if !value.isEmpty { return value }
                }
            }
        }
        return nil
    }

    private static func extractPositivePort(from line: String, flags: [String]) -> Int? {
        guard let raw = extractFlag(from: line, flags: flags),
              let port = Int(raw), port > 0 else {
            return nil
        }
        return port
    }
}
