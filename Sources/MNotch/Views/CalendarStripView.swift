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
                HStack(alignment: .top, spacing: 16) {
                    leftColumn
                    if SettingsStore.shared.calendarMonthView {
                        MonthGridView(eventDays: calendar.monthEventDays)
                    } else {
                        upcomingColumn
                    }
                }
            }
        }
        // Below the tab-button band, which now flanks BOTH top corners.
        .padding(.top, viewModel.geometry.notchHeight + 8)
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

    /// Alcove's left column: the big weekday + day, then today's events, then —
    /// per the "Upcoming events" setting — the next days' events under compact
    /// day labels, so a quiet today still shows the week/month ahead.
    private var leftColumn: some View {
        let showUpcoming = SettingsStore.shared.calendarUpcomingScope != "off"
        // Shared row budget keeps the column from outgrowing the panel.
        let todayItems = Array(calendar.today.prefix(3))
        let sectionBudget = max(0, (5 - todayItems.count) / 2)

        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: -2) {
                Text(Date().formatted(.dateTime.weekday(.abbreviated)).uppercased())
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.red)
                    .kerning(0.5)
                Text(Date().formatted(.dateTime.day()))
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 5) {
                ForEach(todayItems) { item in
                    EventChip(item: item)
                }
                if showUpcoming {
                    ForEach(calendar.upcoming.prefix(sectionBudget)) { section in
                        Text(Self.dayLabel(section.day))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.45))
                            .kerning(0.6)
                            .padding(.top, 2)
                        ForEach(section.items.prefix(2)) { item in
                            EventChip(item: item)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Fallback right column when the month grid is off: upcoming days as a
    /// labelled list, sized to the grid's slot so the panel width is stable.
    private var upcomingColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(calendar.upcoming) { section in
                Text(Self.dayLabel(section.day))
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
                    .kerning(0.6)
                ForEach(section.items.prefix(2)) { item in
                    EventChip(item: item)
                }
            }
        }
        .frame(width: 190, alignment: .leading)
    }

    static func dayLabel(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInTomorrow(day) { return L10n.string("TMRW") }
        let ahead = cal.dateComponents(
            [.day], from: cal.startOfDay(for: Date()), to: day
        ).day ?? 0
        // Within a week a weekday reads naturally; beyond that the weekday is
        // ambiguous, so switch to day + month.
        return ahead < 7
            ? day.formatted(.dateTime.weekday(.abbreviated).day()).uppercased()
            : day.formatted(.dateTime.day().month(.abbreviated)).uppercased()
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
            Text(LocalizedStringKey(text))
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
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(tint)
                .frame(width: 14, height: 14)
                .overlay {
                    Image(systemName: "calendar")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                }
            if !item.isAllDay {
                Text(item.start, style: .time)
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
            }
            Text(item.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.white.opacity(0.07), in: Capsule())
        .frame(maxWidth: 300, alignment: alignment)
    }
}
