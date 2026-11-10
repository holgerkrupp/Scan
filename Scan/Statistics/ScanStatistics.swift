import Foundation

/// One entry in the scan history: a finished scan job (pages received from
/// the scanner) or an export (files written). Both carry the scanner they
/// belong to, so statistics can be shown per scanner.
struct ScanRecord: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case scan, export }
    enum Outcome: String, Codable, Sendable { case completed, failed, cancelled }

    var date: Date
    var scannerID: String
    var kind: Kind
    /// Scan: pages received from the scanner. Export: pages written.
    var pages: Int = 0
    /// Scan: pages hidden by blank-page removal.
    var blankPages: Int = 0
    /// Export: files written.
    var files: Int = 0
    /// Export: bytes on disk after ocrmypdf.
    var bytes: Int64 = 0
    /// Scan: seconds from pressing Scan until the scanner finished.
    var duration: TimeInterval = 0
    var outcome: Outcome = .completed
}

/// Appends scan records to a JSON file in Application Support (inside the
/// app's sandbox container). The history is small - about 150 bytes per
/// scan - so it is rewritten as a whole on every append.
final class ScanStatisticsStore {
    static let shared = ScanStatisticsStore()

    let fileURL: URL
    private let defaults: UserDefaults
    private let recordingKey = "scan.statistics.enabled"

    init(fileURL: URL = ScanStatisticsStore.defaultFileURL, defaults: UserDefaults = .standard) {
        self.fileURL = fileURL
        self.defaults = defaults
    }

    /// Whether new scans and exports are recorded (default on). Turning it
    /// off keeps the history that already exists.
    var isRecording: Bool {
        get { defaults.object(forKey: recordingKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: recordingKey) }
    }

    static var defaultFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Scan", isDirectory: true).appendingPathComponent("ScanStatistics.json")
    }

    func load() -> [ScanRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder.statistics.decode([ScanRecord].self, from: data)) ?? []
    }

    func append(_ record: ScanRecord) {
        guard isRecording else { return }
        var records = load()
        records.append(record)
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder.statistics.encode(records).write(to: fileURL, options: .atomic)
        } catch {
            ScanSystemLog.write("Could not save scan statistics: \(error.localizedDescription)")
        }
    }
}

private extension JSONEncoder {
    static var statistics: JSONEncoder { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; return encoder }
}

private extension JSONDecoder {
    static var statistics: JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }
}

/// Figures for the Statistics topic of the scanner details, computed from
/// the history. `scannerID` nil covers all scanners. Pure, so it is tested
/// with a fixed calendar and date.
struct ScanStatistics {
    struct Period: Equatable {
        var scans = 0
        var pages = 0
        var files = 0
    }

    struct MonthPages: Identifiable, Equatable {
        let month: Date
        let pages: Int
        var id: Date { month }
    }

    let total: Period
    let thisYear: Period
    let thisMonth: Period
    let thisWeek: Period
    let today: Period
    let blankPagesRemoved: Int
    let bytesWritten: Int64
    let completedScans: Int
    let failedScans: Int
    let cancelledScans: Int
    let largestScanPages: Int
    let averagePagesPerScan: Double?
    let averageScanDuration: TimeInterval?
    let pagesPerMinute: Double?
    let averageFileSize: Int64?
    let busiestDay: (date: Date, pages: Int)?
    let firstRecord: Date?
    let lastScan: Date?
    /// The last 12 months including the current one, oldest first.
    let pagesPerMonth: [MonthPages]
    /// Pages scanned per day (start of day), for the activity grid.
    let pagesByDay: [Date: Int]

    init(records allRecords: [ScanRecord], scannerID: String?, now: Date = Date(), calendar: Calendar = .current) {
        let records = allRecords.filter { scannerID == nil || $0.scannerID == scannerID }
        let scans = records.filter { $0.kind == .scan }
        let exports = records.filter { $0.kind == .export }

        func period(_ component: Calendar.Component) -> Period {
            guard let interval = calendar.dateInterval(of: component, for: now) else { return Period() }
            return Self.period(scans: scans.filter { interval.contains($0.date) }, exports: exports.filter { interval.contains($0.date) })
        }
        total = Self.period(scans: scans, exports: exports)
        thisYear = period(.year)
        thisMonth = period(.month)
        thisWeek = period(.weekOfYear)
        today = period(.day)

        blankPagesRemoved = scans.reduce(0) { $0 + $1.blankPages }
        bytesWritten = exports.reduce(0) { $0 + $1.bytes }
        completedScans = scans.filter { $0.outcome == .completed }.count
        failedScans = scans.filter { $0.outcome == .failed }.count
        cancelledScans = scans.filter { $0.outcome == .cancelled }.count

        let productive = scans.filter { $0.pages > 0 }
        largestScanPages = productive.map(\.pages).max() ?? 0
        averagePagesPerScan = productive.isEmpty ? nil : Double(productive.reduce(0) { $0 + $1.pages }) / Double(productive.count)
        let timed = productive.filter { $0.duration > 0 }
        let scanSeconds = timed.reduce(0) { $0 + $1.duration }
        averageScanDuration = timed.isEmpty ? nil : scanSeconds / Double(timed.count)
        pagesPerMinute = scanSeconds > 0 ? Double(timed.reduce(0) { $0 + $1.pages }) / (scanSeconds / 60) : nil
        let fileCount = exports.reduce(0) { $0 + $1.files }
        averageFileSize = fileCount > 0 ? bytesWritten / Int64(fileCount) : nil

        let pagesByDay = Dictionary(grouping: productive) { calendar.startOfDay(for: $0.date) }.mapValues { $0.reduce(0) { $0 + $1.pages } }
        self.pagesByDay = pagesByDay
        busiestDay = pagesByDay.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }.map { ($0.key, $0.value) }
        firstRecord = records.map(\.date).min()
        lastScan = scans.map(\.date).max()

        let currentMonth = calendar.dateInterval(of: .month, for: now)?.start ?? now
        pagesPerMonth = (0..<12).reversed().compactMap { offset -> MonthPages? in
            guard let start = calendar.date(byAdding: .month, value: -offset, to: currentMonth),
                  let interval = calendar.dateInterval(of: .month, for: start) else { return nil }
            return MonthPages(month: interval.start, pages: scans.filter { interval.contains($0.date) }.reduce(0) { $0 + $1.pages })
        }
    }

    private static func period(scans: [ScanRecord], exports: [ScanRecord]) -> Period {
        Period(scans: scans.filter { $0.pages > 0 }.count, pages: scans.reduce(0) { $0 + $1.pages }, files: exports.reduce(0) { $0 + $1.files })
    }
}
