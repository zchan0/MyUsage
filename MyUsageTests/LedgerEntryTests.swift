import Testing
import Foundation
@testable import MyUsage

@Suite("LedgerEntry + Calendar Tests")
struct LedgerEntryTests {

    @Test("LedgerEntry JSON round-trip keeps all fields")
    func jsonRoundTrip() throws {
        let entry = LedgerEntry(
            deviceId: "dev-A",
            provider: .claude,
            day: "2026-04-17",
            costUSD: 1.25,
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(LedgerEntry.self, from: data)
        #expect(decoded == entry)
    }

    @Test("LedgerEntry default sourceHash equals day")
    func defaultSourceHash() {
        let entry = LedgerEntry(
            deviceId: "dev-A",
            provider: .claude,
            day: "2026-04-17",
            costUSD: 1.0
        )
        #expect(entry.sourceHash == "2026-04-17")
    }

    @Test("LedgerCalendar dayKey uses UTC")
    func dayKeyUTC() {
        // 2026-04-17 23:30 UTC — should be 2026-04-17 regardless of local TZ.
        let date = Date(timeIntervalSince1970: 1_776_380_400)
        // Sanity: rebuild in UTC components.
        let key = LedgerCalendar.dayKey(for: date)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        let expected = String(
            format: "%04d-%02d-%02d",
            comps.year ?? 0,
            comps.month ?? 0,
            comps.day ?? 0
        )
        #expect(key == expected)
    }

    @Test("LedgerCalendar monthKey and monthPrefix agree")
    func monthHelpers() {
        let dayKey = "2026-04-17"
        #expect(LedgerCalendar.monthPrefix(of: dayKey) == "2026-04")

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let date = cal.date(from: DateComponents(year: 2026, month: 4, day: 17))!
        #expect(LedgerCalendar.monthKey(for: date) == "2026-04")
    }
}
