import AppKit
import Foundation
import os

/// Driven by the Settings → About update banner. Downloads the latest
/// release's `.zip` to `~/Downloads/`, unzips it in place, then opens
/// Finder selecting the new `MyUsage.app` so the user just has to drag
/// it to `/Applications/`. Stops short of replacing the running app
/// itself (that's Sparkle territory) — this is a half-step between
/// "open release page in browser" and a full self-updater.
@Observable
@MainActor
final class UpdateInstaller {

    static let shared = UpdateInstaller()

    enum State: Equatable, Sendable {
        case idle
        case downloading(progress: Double)   // 0.0 ... 1.0
        case extracting
        case ready(appURL: URL)              // path to the extracted .app
        case failed(message: String)
    }

    private(set) var state: State = .idle

    private let session: URLSession
    private let fileManager: FileManager

    init(
        session: URLSession = .shared,
        fileManager: FileManager = .default
    ) {
        self.session = session
        self.fileManager = fileManager
    }

    /// Cancel any in-flight download / installation and return to idle.
    /// Used when the user closes the banner or starts a fresh install.
    func reset() {
        state = .idle
    }

    /// Download + extract for the given release. Safe to call again on
    /// `.failed` — it restarts from idle.
    func install(release: UpdateChecker.ReleaseInfo) async {
        guard let zipURL = release.zipAssetURL else {
            state = .failed(message: "This release has no .zip asset to download.")
            return
        }

        state = .downloading(progress: 0)

        let downloadsDir: URL
        do {
            downloadsDir = try fileManager.url(
                for: .downloadsDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            state = .failed(message: "Couldn't open Downloads folder: \(error.localizedDescription)")
            return
        }

        let zipDestination = downloadsDir.appendingPathComponent("MyUsage-\(release.version).zip")
        let extractDir = downloadsDir.appendingPathComponent("MyUsage-\(release.version)")

        do {
            try await download(from: zipURL, to: zipDestination)
        } catch {
            state = .failed(message: "Download failed: \(error.localizedDescription)")
            return
        }

        state = .extracting
        do {
            try unzip(at: zipDestination, into: extractDir)
        } catch {
            state = .failed(message: "Extract failed: \(error.localizedDescription)")
            return
        }

        guard let appURL = locateApp(in: extractDir) else {
            state = .failed(message: "Couldn't find MyUsage.app inside the downloaded archive.")
            return
        }

        state = .ready(appURL: appURL)
        revealInFinder(appURL)
    }

    /// Re-reveal the previously extracted .app. Used when the banner is
    /// already in `.ready` state and the user clicks "Show in Finder"
    /// after closing the original Finder window.
    func revealReady() {
        if case .ready(let url) = state {
            revealInFinder(url)
        }
    }

    // MARK: - Steps

    private func download(from url: URL, to destination: URL) async throws {
        // Discard any partial / previous download.
        try? fileManager.removeItem(at: destination)

        let (bytes, response) = try await session.bytes(from: url)
        let expected = response.expectedContentLength
        guard expected > 0 else {
            // Length unknown — fall back to a single-shot data load with
            // indeterminate progress.
            let (data, _) = try await session.data(from: url)
            try data.write(to: destination, options: .atomic)
            state = .downloading(progress: 1.0)
            return
        }

        fileManager.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var written: Int64 = 0
        var buffer = Data(capacity: 64 * 1024)
        var nextThrottle = Date()

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 64 * 1024 {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)

                // Throttle UI updates to at most 10 Hz; setting `state` in
                // a tight loop pegs the main thread.
                if Date() >= nextThrottle {
                    let progress = Double(written) / Double(expected)
                    state = .downloading(progress: min(progress, 0.99))
                    nextThrottle = Date().addingTimeInterval(0.1)
                }
            }
        }

        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            written += Int64(buffer.count)
        }
        state = .downloading(progress: 1.0)
    }

    /// Wraps `/usr/bin/unzip -q -o`. We use the system unzip rather than
    /// rolling our own through Apple's archive APIs because unzip ships
    /// on every macOS, has zero foot-guns for our use case, and matches
    /// what users see if they double-click the `.zip` themselves.
    private func unzip(at zip: URL, into destination: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", "-o", zip.path, "-d", destination.path]

        let stderr = Pipe()
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorOutput = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "exit code \(process.terminationStatus)"
            throw NSError(
                domain: "UpdateInstaller",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: errorOutput]
            )
        }
    }

    /// Find the `.app` bundle inside the extracted directory. The release
    /// workflow ships a flat `MyUsage.app` at the zip root, but we
    /// descend one level just in case future zips wrap it in a folder.
    private func locateApp(in directory: URL) -> URL? {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return nil }

        if let direct = entries.first(where: { $0.pathExtension == "app" }) {
            return direct
        }
        // Look one level deeper.
        for entry in entries {
            if let nested = try? fileManager.contentsOfDirectory(
                at: entry,
                includingPropertiesForKeys: nil
            ).first(where: { $0.pathExtension == "app" }) {
                return nested
            }
        }
        return nil
    }

    private func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
