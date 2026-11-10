import Charts
import SwiftUI

/// "Statistics" topic of the scanner details: scans, pages and files for
/// this scanner (or all scanners) today, this week, month, year and in
/// total, pages per month, and further figures from the scan history.
struct ScannerStatisticsView: View {
    let identity: ScannerIdentity
    private let store = ScanStatisticsStore.shared
    @State private var records: [ScanRecord] = []
    @State private var allScanners = false
    @State private var isRecording = true

    private var statistics: ScanStatistics {
        ScanStatistics(records: records, scannerID: allScanners ? nil : identity.id)
    }

    var body: some View {
        let stats = statistics
        Form {
            Section {
                Picker("Show", selection: $allScanners) {
                    Text("This scanner").tag(false)
                    Text("All scanners").tag(true)
                }
                .pickerStyle(.segmented)
                if let first = stats.firstRecord {
                    Text("Recorded since \(first.formatted(date: .long, time: .omitted)).").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("No scans recorded yet. Scan records the history from now on; earlier scans are not counted.").font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                Grid(alignment: .trailing, horizontalSpacing: 24, verticalSpacing: 8) {
                    GridRow {
                        Text("").gridColumnAlignment(.leading)
                        Text("Scans").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text("Pages").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text("Files").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    Divider()
                    periodRow("Today", stats.today)
                    periodRow("This week", stats.thisWeek)
                    periodRow("This month", stats.thisMonth)
                    periodRow("This year", stats.thisYear)
                    Divider()
                    periodRow("Total", stats.total, emphasized: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } header: {
                Label("Scanned", systemImage: "doc.on.doc")
            }

            Section {
                ScanActivityGrid(year: Calendar.current.component(.year, from: Date()), pagesByDay: stats.pagesByDay)
            } header: {
                Label("Activity \(String(Calendar.current.component(.year, from: Date())))", systemImage: "square.grid.3x3.fill")
            }

            Section {
                Chart(stats.pagesPerMonth) { month in
                    BarMark(x: .value("Month", month.month, unit: .month), y: .value("Pages", month.pages))
                        .foregroundStyle(.tint)
                }
                .chartXAxis { AxisMarks(values: .stride(by: .month)) { _ in AxisValueLabel(format: .dateTime.month(.narrow)) } }
                .frame(height: 150)
            } header: {
                Label("Pages per month", systemImage: "chart.bar.xaxis")
            }

            Section {
                LabeledContent("Completed scans", value: "\(stats.completedScans)")
                LabeledContent("Failed scans", value: "\(stats.failedScans)")
                LabeledContent("Cancelled scans", value: "\(stats.cancelledScans)")
                LabeledContent("Blank pages removed", value: "\(stats.blankPagesRemoved)")
                LabeledContent("Average pages per scan", value: stats.averagePagesPerScan.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "–")
                LabeledContent("Largest scan", value: stats.largestScanPages > 0 ? "\(stats.largestScanPages) pages" : "–")
                LabeledContent("Average scan time", value: stats.averageScanDuration.map { Duration.seconds($0).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated)) } ?? "–")
                LabeledContent("Scanning speed", value: stats.pagesPerMinute.map { "\($0.formatted(.number.precision(.fractionLength(1)))) pages/min" } ?? "–")
                LabeledContent("Data written", value: ByteCountFormatter.string(fromByteCount: stats.bytesWritten, countStyle: .file))
                LabeledContent("Average file size", value: stats.averageFileSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "–")
                LabeledContent("Busiest day", value: stats.busiestDay.map { "\($0.date.formatted(date: .abbreviated, time: .omitted)) · \($0.pages) pages" } ?? "–")
                LabeledContent("Last scan", value: stats.lastScan?.formatted(date: .abbreviated, time: .shortened) ?? "–")
            } header: {
                Label("Details", systemImage: "list.bullet.rectangle")
            }

            Section {
                Toggle("Record scan statistics", isOn: $isRecording)
                Text(isRecording
                     ? "Every scan and export is counted for its scanner. The history stays on this Mac."
                     : "New scans are not counted. The figures above stay as they are.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            records = store.load()
            isRecording = store.isRecording
        }
        .onChange(of: isRecording) { _, newValue in store.isRecording = newValue }
    }

    private func periodRow(_ title: String, _ period: ScanStatistics.Period, emphasized: Bool = false) -> some View {
        GridRow {
            Text(title).fontWeight(emphasized ? .semibold : .regular)
            Text("\(period.scans)").monospacedDigit()
            Text("\(period.pages)").monospacedDigit().fontWeight(emphasized ? .semibold : .regular)
            Text("\(period.files)").monospacedDigit()
        }
    }
}
