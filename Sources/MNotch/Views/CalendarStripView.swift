import SwiftUI

/// Calendar tab, Alcove-style: big "FRI 3" with today's events on the left,
/// upcoming days ("TMRW", "TUE, 7") right-aligned on the right.
struct CalendarStripView: View {
    let viewModel: NotchViewModel
    let calendar: CalendarService

    var body: some View {
        Group {
            if !calendar.authorized && calendar.requested {
                accessNeeded
            } else if calendar.today.isEmpty && calendar.upcoming.isEmpty {
                message("No upcoming events", symbol: "checkmark.circle")
            } else {
                HStack(alignment: .top, spacing: 18) {
                    dateBlock
                    eventsColumn
                }
            }
        }
        .padding(.top, viewModel.geometry.notchHeight - 6)
        .padding(.horizontal, 26)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear {
            // Pick up a grant just made in System Settings, then start/refresh.
            calendar.permissionMayHaveChanged()
            calendar.ensureStarted()
            calendar.reload()
        }
    }

    /// Big date (or the mini month grid) anchoring the left edge.
    private var dateBlock: some View {
        Group {
            if SettingsStore.shared.calendarMonthView {
                MonthGridView(eventDays: calendar.monthEventDays)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text(Date().formatted(.dateTime.weekday(.abbreviated)).uppercased())
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.red)
                        .kerning(0.5)
                    Text(Date().formatted(.dateTime.day()))
                        .font(.system(size: 38, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .fixedSize()
    }

    /// One left-aligned flow: today's events, then each upcoming day under its
    /// label. Fills the remaining width so nothing floats off in a corner.
    private var eventsColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(calendar.today.prefix(3)) { item in
                EventChip(item: item)
            }
            ForEach(calendar.upcoming) { section in
                Text(Self.dayLabel(section.day))
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
                    .kerning(0.6)
                    .padding(.top, calendar.today.isEmpty ? 0 : 3)
                ForEach(section.items.prefix(2)) { item in
                    EventChip(item: item)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func dayLabel(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInTomorrow(day) { return "TMRW" }
        return day.formatted(.dateTime.weekday(.abbreviated).day())
            .uppercased()
    }

    private var accessNeeded: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 20))
                .foregroundStyle(.white.opacity(0.35))
            Text("Calendar access needed")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.45))
            Button {
                calendar.requestAccess()
            } label: {
                Text("Grant Access")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .background(Color.accentColor, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 104)
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

/// Rounded event pill tinted with the calendar's color, like Alcove's. Hugs its
/// title, capped so a very long name truncates instead of spanning the panel.
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
        .frame(maxWidth: 320, alignment: alignment)
    }
}
