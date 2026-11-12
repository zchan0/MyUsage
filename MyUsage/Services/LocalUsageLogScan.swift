import Foundation

/// Shared file selection, timestamp handling, and calendar bucketing for local usage.
struct LocalUsageLogScan {
    private let now: Date
    private let calendar: Calendar
    private let todayStart: Date
    let windowStart: Date
    private var daily: [Date: [String: LocalUsageReport.ModelMetrics]] = [:]
    private var hourlyToday: [Int: [String: LocalUsageReport.ModelMetrics]] = [:]

    init(now: Date, calendar: Calendar) {
        self.now = now
        self.calendar = calendar
        let today = calendar.startOfDay(for: now)
        todayStart = today
        let start = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        windowStart = calendar.startOfDay(for: start)
    }

    func files(in roots: [URL]) -> [URL] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        var files: Set<URL> = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                                                  options: [.skipsHiddenFiles]) else { continue }
            for case let file as URL in enumerator where file.pathExtension == "jsonl" {
                guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true,
                      let mtime = values.contentModificationDate, mtime >= windowStart else { continue }
                files.insert(file.standardizedFileURL)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    private static let fractionalTimestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let wholeSecondTimestamp = Date.ISO8601FormatStyle()

    static func readRows<Row: Decodable>(
        in file: URL,
        decoder: JSONDecoder,
        timestamp: KeyPath<Row, String?>,
        visit: @escaping (Row, Date?) -> Void
    ) {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return }
        let text = String(decoding: data, as: UTF8.self)
        var lastTimestamp: Date?
        text.enumerateLines { line, _ in
            guard !line.isEmpty else { return }
            guard let row = try? decoder.decode(Row.self, from: Data(line.utf8)) else { return }
            if let raw = row[keyPath: timestamp],
               let parsed = (try? fractionalTimestamp.parse(raw)) ?? (try? wholeSecondTimestamp.parse(raw)) {
                lastTimestamp = parsed
            }
            visit(row, lastTimestamp)
        }
    }

    mutating func add(_ metrics: LocalUsageReport.ModelMetrics, for model: String, at timestamp: Date) {
        guard timestamp >= windowStart else { return }
        let day = calendar.startOfDay(for: timestamp)
        guard day <= todayStart else { return }
        daily[day, default: [:]][model, default: .init()] += metrics
        if day == todayStart {
            let hour = calendar.component(.hour, from: timestamp)
            hourlyToday[hour, default: [:]][model, default: .init()] += metrics
        }
    }

    func report() -> LocalUsageReport {
        LocalUsageReport.build(daily: daily, hourlyToday: hourlyToday, now: now, calendar: calendar)
    }
}
