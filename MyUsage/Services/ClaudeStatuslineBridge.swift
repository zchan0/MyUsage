import Foundation

/// Settings are changed only by enable/disable actions. No configuration backup is made.
struct ClaudeStatuslineBridge: Sendable {
    let settingsURL: URL
    let directory: URL
    let executableURL: URL

    init(
        settingsURL: URL = ClaudeStatuslineBridge.defaultSettingsURL,
        directory: URL = ClaudeStatuslineStore.defaultDirectory,
        executableURL: URL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    ) {
        self.settingsURL = settingsURL
        self.directory = directory
        self.executableURL = executableURL
    }

    static var defaultSettingsURL: URL {
        let root = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        return root.appendingPathComponent("settings.json")
    }

    private struct Installation: Codable {
        let originalCommand: String?
        let installedCommand: String
    }
    private var installationURL: URL { directory.appendingPathComponent("installation.json") }

    var isInstalled: Bool {
        guard let installation = try? installation(),
              let settings = try? settings().object,
              let line = settings["statusLine"] as? [String: Any] else { return false }
        return line["type"] as? String == "command" && line["command"] as? String == installation.installedCommand
    }
    var hasInstallation: Bool { FileManager.default.fileExists(atPath: installationURL.path) }

    private func installation() throws -> Installation {
        try JSONDecoder().decode(Installation.self, from: ClaudePrivateFiles.read(installationURL))
    }

    private func settings() throws -> (data: Data?, object: [String: Any]) {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return (nil, [:]) }
        let values = try settingsURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true,
              (values.fileSize ?? Int.max) <= 1_048_576 else { throw ClaudeStatuslineError.unsafePath }
        let data = try Data(contentsOf: settingsURL)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeStatuslineError.unsupportedStatusline
        }
        return (data, object)
    }

    func enable() throws {
        try ClaudePrivateFiles.directory(directory)
        try ClaudePrivateFiles.locked(at: directory.appendingPathComponent("installation.lock")) {
            let current = try settings()
            var object = current.object
            let line = object["statusLine"] as? [String: Any]
            if object["statusLine"] != nil {
                guard line?["type"] as? String == "command", line?["command"] is String else {
                    throw ClaudeStatuslineError.unsupportedStatusline
                }
            }
            let command = line?["command"] as? String
            let saved: Installation
            if hasInstallation {
                saved = try installation()
                guard command == saved.installedCommand || command == saved.originalCommand else {
                    throw ClaudeStatuslineError.settingsChanged
                }
            } else {
                saved = Installation(originalCommand: command, installedCommand: makeCommand(original: command))
            }
            // Record only the command we own before changing the settings. A failed install can be retried.
            try ClaudePrivateFiles.atomicWrite(JSONEncoder().encode(saved), to: installationURL)
            var updated = line ?? [:]
            updated["type"] = "command"
            updated["command"] = saved.installedCommand
            object["statusLine"] = updated
            if command != saved.installedCommand { try save(object, replacing: current.data) }
        }
    }

    func disable() throws {
        guard hasInstallation else { return }
        try ClaudePrivateFiles.directory(directory)
        try ClaudePrivateFiles.locked(at: directory.appendingPathComponent("installation.lock")) {
            guard hasInstallation else { return }
            let saved = try installation()
            let current = try settings()
            var object = current.object
            var line = object["statusLine"] as? [String: Any] ?? [:]
            let command = line["command"] as? String
            if command != saved.originalCommand {
                guard command == saved.installedCommand, line["type"] as? String == "command" else {
                    throw ClaudeStatuslineError.settingsChanged
                }
                if let original = saved.originalCommand {
                    line["command"] = original
                } else {
                    line.removeValue(forKey: "command")
                    line.removeValue(forKey: "type")
                }
                object["statusLine"] = line.isEmpty ? nil : line
                try save(object, replacing: current.data)
            }
            try FileManager.default.removeItem(at: installationURL)
        }
    }

    private func save(_ object: [String: Any], replacing old: Data?) throws {
        let current = try settings()
        guard current.data == old else { throw ClaudeStatuslineError.settingsChanged }
        let parent = settingsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try ClaudePrivateFiles.atomicWrite(JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
                                          to: settingsURL)
    }

    /// The stdin lives only in shell memory. A sentinel preserves trailing newlines.
    /// The original command gets the same bytes, stdout/stderr and exit status, even if collection fails.
    func makeCommand(original: String?) -> String {
        let body = """
        __myusage_input="$(/bin/cat; /usr/bin/printf '\\001')"
        __myusage_input="${__myusage_input%?}"
        /usr/bin/printf '%s' "$__myusage_input" | \(Self.quote(executableURL.path)) --claude-statusline \(Self.quote(directory.path)) >/dev/null 2>&1
        \(original.map { "/usr/bin/printf '%s' \"$__myusage_input\" | /bin/bash -c \(Self.quote($0))" } ?? ":")
        """
        return "/bin/bash -c \(Self.quote(body))"
    }

    private static func quote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum ClaudeStatuslineCommand {
    /// Called before SwiftUI/AppKit startup. Does not initialize providers or launch the app.
    static func run(arguments: [String]) -> Int32 {
        guard arguments.count == 3, arguments[1] == "--claude-statusline" else { return 1 }
        do {
            var input = Data()
            while input.count <= 1_048_576 {
                let chunk = try FileHandle.standardInput.read(upToCount: min(65_536, 1_048_577 - input.count)) ?? Data()
                if chunk.isEmpty { break }
                input.append(chunk)
            }
            try ClaudeStatuslineStore(directory: URL(fileURLWithPath: arguments[2], isDirectory: true)).write(input)
            return 0
        } catch { return 1 } // Never put input, session contents, or errors on the statusline.
    }
}
