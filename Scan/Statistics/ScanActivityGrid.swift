import SwiftUI

/// GitHub-style activity grid for one year: a column per week, a row per
/// weekday, each square shaded by the pages scanned that day.
struct ScanActivityGrid: View {
    let year: Int
    let pagesByDay: [Date: Int]
    var calendar: Calendar = .current

    private let cell: CGFloat = 10
    private let spacing: CGFloat = 2

    var body: some View {
        let layout = ScanActivityLayout(year: year, pagesByDay: pagesByDay, calendar: calendar)
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 3) {
                    // Month names above the week in which each month starts.
                    HStack(alignment: .top, spacing: spacing) {
                        Color.clear.frame(width: 26, height: 1)
                        ForEach(layout.weeks.indices, id: \.self) { index in
                            Text(layout.monthLabel(forWeek: index) ?? "")
                                .font(.system(size: 9)).foregroundStyle(.secondary)
                                .fixedSize()
                                .frame(width: cell, alignment: .leading)
                        }
                    }
                    HStack(alignment: .top, spacing: spacing) {
                        VStack(alignment: .trailing, spacing: spacing) {
                            ForEach(0..<7, id: \.self) { row in
                                Text(row % 2 == 0 ? layout.weekdaySymbol(row) : "")
                                    .font(.system(size: 9)).foregroundStyle(.secondary)
                                    .frame(width: 26, height: cell, alignment: .trailing)
                            }
                        }
                        ForEach(layout.weeks.indices, id: \.self) { index in
                            VStack(spacing: spacing) {
                                ForEach(layout.weeks[index], id: \.self) { day in
                                    square(for: day, layout: layout)
                                }
                            }
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                Text("\(layout.totalPages) page\(layout.totalPages == 1 ? "" : "s") on \(layout.activeDays) day\(layout.activeDays == 1 ? "" : "s") in \(String(year))").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("Less").font(.caption2).foregroundStyle(.secondary)
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2).fill(Self.color(level: level)).frame(width: cell, height: cell)
                }
                Text("More").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func square(for day: Date?, layout: ScanActivityLayout) -> some View {
        if let day {
            let pages = pagesByDay[day] ?? 0
            RoundedRectangle(cornerRadius: 2)
                .fill(Self.color(level: layout.level(for: pages)))
                .frame(width: cell, height: cell)
                .help("\(pages) page\(pages == 1 ? "" : "s") on \(day.formatted(date: .abbreviated, time: .omitted))")
        } else {
            Color.clear.frame(width: cell, height: cell)
        }
    }

    static func color(level: Int) -> Color {
        level == 0 ? Color.secondary.opacity(0.15) : Color.accentColor.opacity([0, 0.35, 0.55, 0.75, 1.0][min(level, 4)])
    }
}

/// The grid's geometry and shading levels, separate from the view so it can
/// be tested: weeks start on the calendar's first weekday, days outside the
/// year are nil, and levels split the busiest day into quarters like GitHub.
struct ScanActivityLayout {
    let weeks: [[Date?]]
    let totalPages: Int
    let activeDays: Int
    private let maximum: Int
    private let calendar: Calendar

    init(year: Int, pagesByDay: [Date: Int], calendar: Calendar) {
        self.calendar = calendar
        let yearStart = calendar.date(from: DateComponents(year: year, month: 1, day: 1))!
        let yearEnd = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1))!
        let leading = (calendar.component(.weekday, from: yearStart) - calendar.firstWeekday + 7) % 7
        var days: [Date?] = Array(repeating: nil, count: leading)
        var day = yearStart
        while day < yearEnd {
            days.append(day)
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        days += Array(repeating: nil, count: (7 - days.count % 7) % 7)
        weeks = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<$0 + 7]) }

        let inYear = pagesByDay.filter { $0.key >= yearStart && $0.key < yearEnd && $0.value > 0 }
        totalPages = inYear.values.reduce(0, +)
        activeDays = inYear.count
        maximum = inYear.values.max() ?? 0
    }

    func level(for pages: Int) -> Int {
        guard pages > 0, maximum > 0 else { return 0 }
        return min(4, Int((Double(pages) / Double(maximum) * 4).rounded(.up)))
    }

    /// Short month name when the month's first day falls in this week.
    func monthLabel(forWeek index: Int) -> String? {
        guard let first = weeks[index].compactMap({ $0 }).first(where: { calendar.component(.day, from: $0) == 1 }) else { return nil }
        return calendar.shortMonthSymbols[calendar.component(.month, from: first) - 1]
    }

    func weekdaySymbol(_ row: Int) -> String {
        calendar.veryShortWeekdaySymbols[(calendar.firstWeekday - 1 + row) % 7]
    }
}
