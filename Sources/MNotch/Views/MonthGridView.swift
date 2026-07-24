import SwiftUI

/// Alcove-style mini month grid for the calendar tab: weekday header, day
/// numbers, weekends dimmed, today in a filled circle, event days dotted.
struct MonthGridView: View {
    let eventDays: Set<Int>

    private let calendar = Calendar.current
    private let cell: CGFloat = 20

    private var monthInfo: (days: Int, leadingBlanks: Int, today: Int, firstWeekday: Int) {
        let now = Date()
        let range = calendar.range(of: .day, in: .month, for: now) ?? 1..<31
        let firstOfMonth = calendar.dateInterval(of: .month, for: now)?.start ?? now
        let firstWeekday = calendar.component(.weekday, from: firstOfMonth)
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7
        return (range.count, leading, calendar.component(.day, from: now), firstWeekday)
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// Weekday (1 = Sun … 7 = Sat) shown in grid column `col`.
    private func weekday(forColumn col: Int) -> Int {
        (calendar.firstWeekday - 1 + col) % 7 + 1
    }

    private func isWeekend(_ weekday: Int) -> Bool {
        weekday == 1 || weekday == 7
    }

    var body: some View {
        let info = monthInfo
        let columns = Array(repeating: GridItem(.fixed(cell), spacing: 3), count: 7)

        LazyVGrid(columns: columns, spacing: 3) {
            ForEach(0..<7, id: \.self) { col in
                Text(weekdaySymbols[col])
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(isWeekend(weekday(forColumn: col)) ? 0.28 : 0.5))
                    .frame(width: cell)
            }
            ForEach(0..<info.leadingBlanks, id: \.self) { _ in
                Color.clear.frame(width: cell, height: cell)
            }
            ForEach(1...info.days, id: \.self) { day in
                dayCell(day, info: info)
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private func dayCell(_ day: Int, info: (days: Int, leadingBlanks: Int, today: Int, firstWeekday: Int)) -> some View {
        let isToday = day == info.today
        // Column of this day → its weekday, to dim weekends like Alcove.
        let column = (info.leadingBlanks + day - 1) % 7
        let weekend = isWeekend(weekday(forColumn: column))
        let hasEvent = eventDays.contains(day)

        Text("\(day)")
            .font(.system(size: 11, weight: isToday ? .bold : .medium).monospacedDigit())
            .foregroundStyle(
                isToday ? AnyShapeStyle(.black)
                    : AnyShapeStyle(.white.opacity(weekend ? 0.3 : 0.85))
            )
            .frame(width: cell, height: cell)
            .background(Circle().fill(isToday ? Color.white : .clear))
            .overlay(alignment: .bottom) {
                if hasEvent, !isToday {
                    Circle()
                        .fill(.red)
                        .frame(width: 3, height: 3)
                        .offset(y: 2)
                }
            }
    }
}
