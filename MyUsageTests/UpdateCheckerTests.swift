import Testing
import Foundation
@testable import MyUsage

@Suite("UpdateChecker version comparison")
struct UpdateCheckerTests {

    @Test("strips leading 'v' from tag names")
    func stripsTagPrefix() {
        #expect(UpdateChecker.stripTagPrefix("v0.6.2") == "0.6.2")
        #expect(UpdateChecker.stripTagPrefix("0.6.2") == "0.6.2")
        #expect(UpdateChecker.stripTagPrefix("v1.0") == "1.0")
        #expect(UpdateChecker.stripTagPrefix("v") == "")
    }

    @Test("recognizes a strictly newer remote")
    func isNewerStrict() {
        #expect(UpdateChecker.isNewer(remote: "0.6.2", local: "0.6.1"))
        #expect(UpdateChecker.isNewer(remote: "0.7.0", local: "0.6.99"))
        #expect(UpdateChecker.isNewer(remote: "1.0.0", local: "0.99.99"))
    }

    @Test("returns false when versions match")
    func equalVersions() {
        #expect(!UpdateChecker.isNewer(remote: "0.6.1", local: "0.6.1"))
        #expect(!UpdateChecker.isNewer(remote: "1.0.0", local: "1.0.0"))
    }

    @Test("returns false when local is newer")
    func localNewer() {
        #expect(!UpdateChecker.isNewer(remote: "0.6.0", local: "0.6.1"))
        #expect(!UpdateChecker.isNewer(remote: "0.5.99", local: "0.6.0"))
    }

    @Test("tolerates differing component counts")
    func differingComponents() {
        #expect(!UpdateChecker.isNewer(remote: "1.0.0", local: "1.0"))
        #expect(!UpdateChecker.isNewer(remote: "1.0", local: "1.0.0"))
        #expect(UpdateChecker.isNewer(remote: "1.0.1", local: "1.0"))
        #expect(!UpdateChecker.isNewer(remote: "1.0", local: "1.0.1"))
    }

    @Test("ignores pre-release suffixes")
    func ignoresPreRelease() {
        #expect(UpdateChecker.isNewer(remote: "0.7.0-rc.1", local: "0.6.1"))
        // 0.7.0-rc.1 and 0.7.0 compare as equal because we strip the suffix.
        // We accept that loss; pre-release tagging isn't planned for this app.
        #expect(!UpdateChecker.isNewer(remote: "0.7.0-rc.1", local: "0.7.0"))
    }

    // The "dev" fallback version (returned by AppInfo.version when running
    // from `swift run` without an Info.plist) is guarded inside check()
    // itself — early return before the version comparison runs. The pure
    // isNewer() helper would treat "dev" → all-zeros and falsely flag any
    // release as newer, which is why check() does the dev-mode guard.
}
