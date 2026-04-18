import Foundation
import os

enum AppResources {
    static let resourceBundleName = "MyUsage_MyUsage.bundle"

    static let bundle: Bundle? = {
        for sourceBundle in searchBundles {
            for url in candidateURLs(
                mainBundleURL: sourceBundle.bundleURL,
                resourceURL: sourceBundle.resourceURL,
                executableURL: sourceBundle.executableURL
            ) {
                if let bundle = Bundle(url: url) ?? Bundle(path: url.path) {
                    return bundle
                }
            }
        }

        for url in fallbackCandidateURLs {
            if let bundle = Bundle(url: url) ?? Bundle(path: url.path) {
                return bundle
            }
        }

        Logger.general.error("Missing resource bundle: \(resourceBundleName, privacy: .public)")
        return nil
    }()

    static func url(
        forResource name: String,
        withExtension ext: String?,
        subdirectory: String? = nil
    ) -> URL? {
        for bundle in [bundle, Bundle.main].compactMap({ $0 }) {
            if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: subdirectory) {
                return url
            }
        }
        return nil
    }

    private static var searchBundles: [Bundle] {
        var seen = Set<String>()
        return ([Bundle.main] + Bundle.allBundles + Bundle.allFrameworks).filter {
            seen.insert($0.bundleURL.path).inserted
        }
    }

    private static var fallbackCandidateURLs: [URL] {
        let currentFileURL = URL(fileURLWithPath: #filePath)
        let sourceRoot = currentFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let buildDirectories = [
            sourceRoot.appendingPathComponent(".build/debug", isDirectory: true),
            sourceRoot.appendingPathComponent(".build/release", isDirectory: true),
            sourceRoot.appendingPathComponent(".build/arm64-apple-macosx/debug", isDirectory: true),
            sourceRoot.appendingPathComponent(".build/arm64-apple-macosx/release", isDirectory: true),
        ]

        var seen = Set<String>()
        return buildDirectories
            .map { $0.appendingPathComponent(resourceBundleName, isDirectory: true) }
            .filter { seen.insert($0.path).inserted }
    }

    static func candidateURLs(
        mainBundleURL: URL,
        resourceURL: URL?,
        executableURL: URL?
    ) -> [URL] {
        var urls: [URL] = []

        if let resourceURL {
            urls.append(resourceURL.appendingPathComponent(resourceBundleName, isDirectory: true))
        }

        urls.append(mainBundleURL.appendingPathComponent(resourceBundleName, isDirectory: true))

        if let executableURL {
            urls.append(
                executableURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(resourceBundleName, isDirectory: true)
            )
        }

        var seen = Set<String>()
        return urls.filter { seen.insert($0.path).inserted }
    }
}
