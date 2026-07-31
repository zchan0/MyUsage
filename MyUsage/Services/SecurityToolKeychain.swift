import Foundation
import os

/// Reads a Keychain generic password by shelling out to `/usr/bin/security`.
///
/// This exists to solve a specific, verified macOS behaviour, not as a general
/// alternative to `SecItemCopyMatching`.
///
/// **Why in-process reads keep prompting.** Since macOS Sierra every legacy
/// Keychain item carries, besides its trusted-application list, an *ACL
/// partition list*: the set of code identities allowed to use the item without
/// a confirmation dialog. Both gates must pass — an app that is in the trusted
/// list but whose partition ID is absent still gets the "enter your keychain
/// password / Always Allow" panel.
///
/// The Claude CLI persists its OAuth tokens with
/// `security add-generic-password -U …`, and that command **rewrites the
/// partition list to exactly `apple-tool:`** while leaving the trusted-app list
/// intact. So every token rotation (~8h) silently revokes the partition entry
/// that the user's previous "Always Allow" installed, and MyUsage's next
/// no-UI read fails with an ACL error again. The user experiences this as a
/// password prompt roughly once a day, forever, with the item's trusted-app
/// list growing one duplicate entry per prompt. Signing MyUsage with a stable
/// identity does **not** help: the reset removes every partition, not just
/// ad-hoc `cdhash:` ones.
///
/// **Why the security tool does not prompt.** `/usr/bin/security` is an Apple
/// tool, so its partition ID is `apple-tool:` — the one identity the CLI's own
/// write always authorizes — and the CLI's `add-generic-password` put
/// `/usr/bin/security` into the trusted-app list when it created the item.
/// Reading through it therefore satisfies both gates on every machine where
/// the CLI wrote the item, with no ACL change, no signing change, and no
/// prompt. It is exactly the path the CLI itself uses to read its token back.
///
/// The subprocess is hard-bounded by `timeout` so a machine in some unforeseen
/// state can never hang a refresh behind a modal panel: if `security` blocks,
/// it is killed and the caller falls through to the existing source chain.
enum SecurityToolKeychain {

    static let executablePath = "/usr/bin/security"

    /// Read a generic password's data, or nil when the item is missing, the
    /// tool is unavailable, or the read did not finish within `timeout`.
    ///
    /// Never logs the payload — only the outcome.
    static func readGenericPassword(
        service: String,
        account: String? = nil,
        timeout: TimeInterval = 3
    ) -> Data? {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            return nil
        }

        var arguments = ["find-generic-password", "-w", "-s", service]
        if let account, !account.isEmpty {
            arguments += ["-a", account]
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            Logger.claude.error("security tool launch failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        // Drain stdout on a background thread: waiting on the process first
        // would deadlock once the payload exceeds the pipe buffer, and reading
        // first would block past the deadline if the tool never writes.
        let readDone = DispatchSemaphore(value: 0)
        let box = OutputBox()
        DispatchQueue.global(qos: .userInitiated).async {
            box.data = try? pipe.fileHandleForReading.readToEnd()
            readDone.signal()
        }

        if readDone.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            // Closing the read end unblocks the drain thread if `terminate`
            // was not enough (a modal ACL panel keeps the child alive).
            try? pipe.fileHandleForReading.close()
            _ = readDone.wait(timeout: .now() + 1)
            Logger.claude.error("security tool read timed out for service \(service, privacy: .public)")
            return nil
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        // `-w` prints the secret followed by a newline.
        guard let data = box.data,
              let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : Data(trimmed.utf8)
    }

    /// Mutable capture box for the drain thread. `nonisolated(unsafe)` is safe
    /// here because the semaphore establishes happens-before ordering between
    /// the single write and the single read.
    private final class OutputBox: @unchecked Sendable {
        var data: Data?
    }
}
