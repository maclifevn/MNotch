import SwiftUI

/// Calendar tab, Alcove-style: big "FRI 3" with today's events on the left,
/// upcoming days ("TMRW", "TUE, 7") right-aligned on the right.
struct CalendarStripView: View {
    let viewModel: NotchViewModel
    let calendar: CalendarService

    var body: some View {
        Group {
            if !calendar.authorized && calendar.requested {
                message("Calendar access needed", symbol: "lock.fill")
            } else if calendar.today.isEmpty && calendar.upcoming.isEmpty {
                message("No upcoming events", symbol: "checkmark.circle")
            } else {
                HStack(alignment: .top, spacing: 16) {
                    todayColumn
                    Spacer(minLength: 0)
                    upcomingColumn
                }
            }
        }
        .padding(.top, viewModel.geometry.notchHeight - 6)
        .padding(.horizontal, 26)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear {
            calendar.ensureStarted()
            calendar.reload()
        }
    }

    private var todayColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            if SettingsStore.shared.calendarMonthView {
                MonthGridView(eventDays: calendar.monthEventDays)
            } else {
                Text(Date().formatted(.dateTime.weekday(.abbreviated)).uppercased())
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.red)
                    .kerning(0.5)
                Text(Date().formatted(.dateTime.day()))
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(calendar.today.prefix(3)) { item in
                    EventChip(item: item)
                }
            }
            .padding(.top, 4)
        }
    }

    private var upcomingColumn: some View {
        VStack(alignment: .trailing, spacing: 5) {
            ForEach(calendar.upcoming) { section in
                Text(Self.dayLabel(section.day))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
                    .kerning(0.5)
                ForEach(section.items) { item in
                    EventChip(item: item, alignment: .trailing)
                }
            }
        }
    }

    static func dayLabel(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInTomorrow(day) { return "TMRW" }
        return day.formatted(.dateTime.weekday(.abbreviated).day())
            .uppercased()
    }

    private func message(_ text: String, symbol: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(.white.opacity(0.35))
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 72)
    }
}

/// Rounded event pill tinted with the calendar's color, like Alcove's.
/// `alignment` pins the pill inside its 165pt slot (leading in the today
/// column, trailing in the right-aligned upcoming column).
struct EventChip: View {
    let item: CalendarService.Item
    var alignment: Alignment = .leading

    private var tint: Color {
        SettingsStore.shared.calendarUseColor
            ? Color(red: item.colorRed, green: item.colorGreen, blue: item.colorBlue)
            : .white.opacity(0.75)
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 5, height: 5)
            if !item.isAllDay {
                Text(item.start, style: .time)
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(tint.opacity(0.9))
            }
            Text(item.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.18), in: Capsule())
        .frame(maxWidth: 165, alignment: alignment)
    }
}
