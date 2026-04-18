import XCTest
@testable import MyUsage

final class AppResourcesTests: XCTestCase {
    func testCandidateURLsPreferContentsResourcesForAppBundles() {
        let appURL = URL(fileURLWithPath: "/Applications/MyUsage.app", isDirectory: true)
        let resourceURL = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        let executableURL = appURL.appendingPathComponent("Contents/MacOS/MyUsage")

        let urls = AppResources.candidateURLs(
            mainBundleURL: appURL,
            resourceURL: resourceURL,
            executableURL: executableURL
        )

        XCTAssertEqual(
            urls.first?.path,
            "/Applications/MyUsage.app/Contents/Resources/\(AppResources.resourceBundleName)"
        )
        XCTAssertEqual(
            urls.dropFirst().first?.path,
            "/Applications/MyUsage.app/\(AppResources.resourceBundleName)"
        )
    }

    func testCandidateURLsIncludeExecutableSiblingForSwiftRun() {
        let buildDir = URL(fileURLWithPath: "/tmp/MyUsage/.build/debug", isDirectory: true)
        let executableURL = buildDir.appendingPathComponent("MyUsage")

        let urls = AppResources.candidateURLs(
            mainBundleURL: buildDir,
            resourceURL: nil,
            executableURL: executableURL
        )

        XCTAssertEqual(
            urls.first?.path,
            "/tmp/MyUsage/.build/debug/\(AppResources.resourceBundleName)"
        )
        XCTAssertEqual(urls.count, 1)
    }
}
