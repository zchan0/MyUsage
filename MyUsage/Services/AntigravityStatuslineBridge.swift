import CoreFoundation
import Foundation

/// Manages explicit opt-in statusLine integration in `~/.gemini/antigravity-cli/settings.json`.
/// Settings are changed only by enable/disable actions; existing statusLine commands and settings
/// are preserved.
struct AntigravityStatuslineBridge: Sendable {
    let settingsURL: URL
    let directory: URL
    let executableURL: URL

    init(
        settingsURL: URL = AntigravityStatuslineBridge.defaultSettingsURL,
        directory: URL = AntigravityStatuslineStore.defaultDirectory,
        executableURL: URL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    ) {
        self.settingsURL = settingsURL
        self.directory = directory
        self.executableURL = executableURL
    }

    static var defaultSettingsURL: URL {
        let override = ProcessInfo.processInfo.environment["ANTIGRAVITY_CLI_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let root = override.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/antigravity-cli")
        return root.appendingPathComponent("settings.json")
    }

    private struct Installation: Codable {
        let originalCommand: String?
        let installedCommand: String
        let originalEnabled: Bool?
        let addedStackWithDefault: Bool
        let addedType: Bool

        init(
            originalCommand: String?,
            installedCommand: String,
            originalEnabled: Bool?,
            addedStackWithDefault: Bool,
            addedType: Bool = false
        ) {
            self.originalCommand = originalCommand
            self.installedCommand = installedCommand
            self.originalEnabled = originalEnabled
            self.addedStackWithDefault = addedStackWithDefault
            self.addedType = addedType
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            originalCommand = try container.decodeIfPresent(String.self, forKey: .originalCommand)
            installedCommand = try container.decode(String.self, forKey: .installedCommand)
            originalEnabled = try container.decodeIfPresent(Bool.self, forKey: .originalEnabled)
            addedStackWithDefault = try container.decodeIfPresent(Bool.self, forKey: .addedStackWithDefault) ?? false
            addedType = try container.decodeIfPresent(Bool.self, forKey: .addedType) ?? false
        }
    }

    private var installationURL: URL { directory.appendingPathComponent("installation.json") }

    var isInstalled: Bool {
        guard let installation = try? installation(),
              let settings = try? settings().object,
              let line = settings["statusLine"] as? [String: Any] else { return false }
        let enabled: Bool
        if let rawEnabled = line["enabled"], !(rawEnabled is NSNull) {
            guard let parsed = Self.boolValue(rawEnabled) else { return false }
            enabled = parsed
        } else {
            enabled = true
        }
        let type: String
        if let rawType = line["type"], !(rawType is NSNull) {
            guard let parsed = rawType as? String else { return false }
            type = parsed
        } else {
            type = "command"
        }
        return enabled && type == "command" && line["command"] as? String == installation.installedCommand
    }

    var hasInstallation: Bool { FileManager.default.fileExists(atPath: installationURL.path) }

    var integrationState: StatuslineBridgeState {
        guard hasInstallation else { return .notInstalled }
        guard isInstalled, let saved = try? installation() else { return .modifiedExternally }
        return saved.installedCommand == makeCommand(original: saved.originalCommand) ? .installed : .appMoved
    }

    func reconnect() throws {
        try disable()
        try enable()
    }

    /// Removes only MyUsage's private installation record without touching `settings.json`.
    func resetInstallationRecord() throws {
        guard hasInstallation else { return }
        try AntigravityStatuslineError.mappingPrivateFileError {
            try ClaudePrivateFiles.directory(directory)
            try ClaudePrivateFiles.locked(at: directory.appendingPathComponent("installation.lock")) {
                guard hasInstallation else { return }
                try FileManager.default.removeItem(at: installationURL)
            }
        }
    }

    private func installation() throws -> Installation {
        let data = try AntigravityStatuslineError.mappingPrivateFileError {
            try ClaudePrivateFiles.read(installationURL)
        }
        return try JSONDecoder().decode(Installation.self, from: data)
    }

    private func settings() throws -> (data: Data?, object: [String: Any]) {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return (nil, [:]) }
        let values = try settingsURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true,
              (values.fileSize ?? Int.max) <= 1_048_576 else {
            throw AntigravityStatuslineError.unsafePath
        }
        let data = try Data(contentsOf: settingsURL)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AntigravityStatuslineError.unsupportedStatusline
        }
        return (data, object)
    }

    func enable() throws {
        try AntigravityStatuslineError.mappingPrivateFileError {
            try ClaudePrivateFiles.directory(directory)
            try ClaudePrivateFiles.locked(at: directory.appendingPathComponent("installation.lock")) {
                let current = try settings()
                var object = current.object
                let line = object["statusLine"] as? [String: Any]
                if let rawStatusLine = object["statusLine"], !(rawStatusLine is NSNull) {
                    guard let line else {
                        throw AntigravityStatuslineError.unsupportedStatusline
                    }
                    if let rawType = line["type"], !(rawType is NSNull) {
                        guard let type = rawType as? String, type == "command" else {
                            throw AntigravityStatuslineError.unsupportedStatusline
                        }
                    }
                    if let rawCommand = line["command"], !(rawCommand is NSNull) {
                        guard rawCommand is String else {
                            throw AntigravityStatuslineError.unsupportedStatusline
                        }
                    }
                    if let rawEnabled = line["enabled"], !(rawEnabled is NSNull) {
                        guard Self.boolValue(rawEnabled) != nil else {
                            throw AntigravityStatuslineError.unsupportedStatusline
                        }
                    }
                }

                let command = line?["command"] as? String
                let existingEnabled = Self.boolValue(line?["enabled"])
                let hadType = line?["type"] is String
                let hadStackWithDefault = line?["stack_with_default"] != nil && !(line?["stack_with_default"] is NSNull)

                let saved: Installation
                if hasInstallation {
                    saved = try installation()
                    guard command == saved.installedCommand || command == saved.originalCommand else {
                        throw AntigravityStatuslineError.settingsChanged
                    }
                } else {
                    // Keep `agy`'s built-in status line visible when MyUsage is the only statusLine command.
                    let shouldAddStackWithDefault = (command == nil && !hadStackWithDefault)
                    saved = Installation(
                        originalCommand: command,
                        installedCommand: makeCommand(original: command),
                        originalEnabled: existingEnabled,
                        addedStackWithDefault: shouldAddStackWithDefault,
                        addedType: !hadType
                    )
                }

                // Record only the command we own before changing settings so a failed install can be retried.
                try ClaudePrivateFiles.atomicWrite(JSONEncoder().encode(saved), to: installationURL)

                var updated = line ?? [:]
                updated["type"] = "command"
                updated["command"] = saved.installedCommand
                if existingEnabled == false {
                    if saved.originalEnabled == false {
                        updated["enabled"] = true
                    } else {
                        // Default for `agy` is enabled=true; remove an externally added enabled=false
                        // so disable() doesn't leave a stray `enabled: true` behind.
                        updated.removeValue(forKey: "enabled")
                    }
                }
                if saved.addedStackWithDefault && !hadStackWithDefault {
                    updated["stack_with_default"] = true
                }
                object["statusLine"] = updated

                let needsSave = command != saved.installedCommand
                    || !hadType
                    || existingEnabled == false
                    || (saved.addedStackWithDefault && !hadStackWithDefault)
                if needsSave {
                    try save(object, replacing: current.data)
                }
            }
        }
    }

    func disable() throws {
        guard hasInstallation else { return }
        try AntigravityStatuslineError.mappingPrivateFileError {
            try ClaudePrivateFiles.directory(directory)
            try ClaudePrivateFiles.locked(at: directory.appendingPathComponent("installation.lock")) {
                guard hasInstallation else { return }
                let saved = try installation()
                let current = try settings()
                var object = current.object
                var line = object["statusLine"] as? [String: Any] ?? [:]
                let command = line["command"] as? String
                let type: String
                if let rawType = line["type"], !(rawType is NSNull) {
                    guard let parsed = rawType as? String else {
                        throw AntigravityStatuslineError.settingsChanged
                    }
                    type = parsed
                } else {
                    type = "command"
                }

                if command != saved.originalCommand {
                    guard command == saved.installedCommand, type == "command" else {
                        throw AntigravityStatuslineError.settingsChanged
                    }
                    if let original = saved.originalCommand {
                        line["command"] = original
                        if saved.addedType, line["type"] as? String == "command" {
                            line.removeValue(forKey: "type")
                        }
                    } else {
                        line.removeValue(forKey: "command")
                        if saved.addedType, line["type"] as? String == "command" {
                            line.removeValue(forKey: "type")
                        }
                    }
                    if let originalEnabled = saved.originalEnabled {
                        line["enabled"] = originalEnabled
                    }
                    if saved.addedStackWithDefault, Self.boolValue(line["stack_with_default"]) == true {
                        line.removeValue(forKey: "stack_with_default")
                    }
                    object["statusLine"] = line.isEmpty ? nil : line
                    try save(object, replacing: current.data)
                }
                try FileManager.default.removeItem(at: installationURL)
            }
        }
    }

    private func save(_ object: [String: Any], replacing old: Data?) throws {
        let current = try settings()
        guard current.data == old else { throw AntigravityStatuslineError.settingsChanged }
        let parent = settingsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try AntigravityStatuslineError.mappingPrivateFileError {
            try ClaudePrivateFiles.atomicWrite(
                JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
                to: settingsURL
            )
        }
    }

    /// Buffers stdin in shell memory (with a sentinel to preserve trailing newlines),
    /// forwards a copy to MyUsage's collector silently, and runs any original command
    /// with identical bytes, stdout/stderr, and exit status.
    func makeCommand(original: String?) -> String {
        let body = """
        __myusage_input="$(/bin/cat; /usr/bin/printf '\\001')"
        __myusage_input="${__myusage_input%?}"
        /usr/bin/printf '%s' "$__myusage_input" | \(Self.quote(executableURL.path)) --antigravity-statusline \(Self.quote(directory.path)) >/dev/null 2>&1
        \(original.map { "/usr/bin/printf '%s' \"$__myusage_input\" | /bin/bash -c \(Self.quote($0))" } ?? ":")
        """
        return "/bin/bash -c \(Self.quote(body))"
    }

    private static func quote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func boolValue(_ raw: Any?) -> Bool? {
        guard let num = raw as? NSNumber, CFGetTypeID(num) == CFBooleanGetTypeID() else { return nil }
        return num.boolValue
    }
}

enum AntigravityStatuslineCommand {
    /// Invoked directly by `agy` before SwiftUI/AppKit startup.
    static func run(arguments: [String]) -> Int32 {
        guard arguments.count == 3, arguments[1] == "--antigravity-statusline" else { return 1 }
        do {
            var input = Data()
            while input.count <= 1_048_576 {
                let chunk = try FileHandle.standardInput.read(upToCount: min(65_536, 1_048_577 - input.count)) ?? Data()
                if chunk.isEmpty { break }
                input.append(chunk)
            }
            try AntigravityStatuslineStore(directory: URL(fileURLWithPath: arguments[2], isDirectory: true)).write(input)
            return 0
        } catch {
            return 1
        }
    }
}
