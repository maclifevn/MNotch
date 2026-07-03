import SwiftUI

/// Mini month grid for the calendar tab: weekday header, day numbers, today
/// highlighted, event days dotted.
struct MonthGridView: View {
    let eventDays: Set<Int>

    private let calendar = Calendar.current

    private var monthInfo: (days: Int, leadingBlanks: Int, today: Int) {
        let now = Date()
        let range = calendar.range(of: .day, in: .month, for: now) ?? 1..<31
        let firstOfMonth = calendar.dateInterval(of: .month, for: now)?.start ?? now
        let firstWeekday = calendar.component(.weekday, from: firstOfMonth)
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7
        return (range.count, leading, calendar.component(.day, from: now))
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    var body: some View {
        let info = monthInfo
        let columns = Array(repeating: GridItem(.flexible(), spacing: 1), count: 7)

        VStack(spacing: 2) {
            LazyVGrid(columns: columns, spacing: 1) {
                ForEach(weekdaySymbols.indices, id: \.self) { i in
                    Text(weekdaySymbols[i])
                        .font(.system(size: 6, weight: .bold))
                        .foregroundStyle(.white.opacity(0.35))
                }
                ForEach(0..<info.leadingBlanks, id: \.self) { _ in
                    Text("")
                }
                ForEach(1...info.days, id: \.self) { day in
                    Text("\(day)")
                        .font(.system(size: 7.5, weight: day == info.today ? .bold : .medium))
                        .foregroundStyle(day == info.today ? .black : .white.opacity(0.8))
                        .frame(width: 13, height: 13)
                        .background(
                            Circle().fill(day == info.today ? .white : .clear)
                        )
                        .overlay(alignment: .bottom) {
                            if eventDays.contains(day), day != info.today {
                                Circle()
                                    .fill(.red)
                                    .frame(width: 2.5, height: 2.5)
                                    .offset(y: 1)
                            }
                        }
                }
            }
        }
        .frame(width: 110)
    }
}
