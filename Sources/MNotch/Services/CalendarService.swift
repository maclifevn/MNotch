import EventKit
import Observation

/// Calendar events via EventKit: today's (including all-day — holidays and
/// birthdays are the events people actually see up here) plus the next week,
/// grouped by day. Access is requested lazily, the first time the calendar
/// tab appears, so launch never triggers a TCC prompt.
@MainActor
@Observable
final class CalendarService {
    struct Item: Identifiable, Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let isAllDay: Bool
        let colorRed: Double
        let colorGreen: Double
        let colorBlue: Double
    }

    /// A timed event is happening right now.
    var hasOngoingEvent: Bool {
        let now = Date()
        return today.contains { !$0.isAllDay && $0.start <= now && $0.end > now }
    }

    /// Next timed event today (for the compact idle chrome and peeks).
    var nextEvent: Item? {
        let now = Date()
        return today.first { !$0.isAllDay && $0.end > now }
            ?? today.first
            ?? upcoming.first?.items.first
    }

    struct DaySection: Identifiable, Equatable {
        let day: Date
        let items: [Item]
        var id: Date { day }
    }

    struct CalendarInfo: Identifiable, Equatable {
        let id: String
        let title: String
        let red: Double
        let green: Double
        let blue: Double
    }

    private(set) var today: [Item] = []
    private(set) var upcoming: [DaySection] = []
    private(set) var calendars: [CalendarInfo] = []
    private(set) var authorized = false
    private(set) var requested = false

    @ObservationIgnored private var store: EKEventStore?

    func ensureStarted() {
        guard !requested else { return }
        requested = true
        let store = EKEventStore()
        self.store = store
        Task { [weak self] in
            let granted = (try? await store.requestFullAccessToEvents()) ?? false
            self?.authorized = granted
            guard granted else { return }
            self?.reload()
            NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged,
                object: store,
                queue: .main
            ) { _ in
                Task { @MainActor in self?.reload() }
            }
        }
    }

    func reload() {
        guard let store, authorized else { return }

        calendars = store.calendars(for: .event).map { cal in
            let c = cal.cgColor?.components ?? [0.6, 0.5, 1, 1]
            return CalendarInfo(
                id: cal.calendarIdentifier,
                title: cal.title,
                red: Double(c.count > 0 ? c[0] : 0.6),
                green: Double(c.count > 1 ? c[1] : 0.5),
                blue: Double(c.count > 2 ? c[2] : 1)
            )
        }.sorted { $0.title < $1.title }

        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now
        let windowEnd = calendar.date(byAdding: .day, value: 8, to: startOfToday) ?? now

        let disabled = SettingsStore.shared.calendarDisabledCalendars
        let enabledCalendars = store.calendars(for: .event)
            .filter { !disabled.contains($0.calendarIdentifier) }
        let predicate = store.predicateForEvents(
            withStart: startOfToday,
            end: windowEnd,
            calendars: enabledCalendars.isEmpty ? nil : enabledCalendars
        )
        let events = store.events(matching: predicate)
            .sorted {
                if $0.isAllDay != $1.isAllDay { return $0.isAllDay }
                return $0.startDate < $1.startDate
            }
            .map { event in
                let color = event.calendar?.cgColor?.components ?? [0.6, 0.5, 1, 1]
                return Item(
                    id: (event.eventIdentifier ?? UUID().uuidString)
                        + "\(event.startDate.timeIntervalSince1970)",
                    title: event.title ?? "Untitled",
                    start: event.startDate,
                    end: event.endDate ?? event.startDate,
                    isAllDay: event.isAllDay,
                    colorRed: Double(color.count > 0 ? color[0] : 0.6),
                    colorGreen: Double(color.count > 1 ? color[1] : 0.5),
                    colorBlue: Double(color.count > 2 ? color[2] : 1)
                )
            }

        today = events
            .filter { $0.start < startOfTomorrow }
            .prefix(3)
            .map { $0 }

        let byDay = Dictionary(grouping: events.filter { $0.start >= startOfTomorrow }) {
            calendar.startOfDay(for: $0.start)
        }
        upcoming = byDay.keys.sorted()
            .prefix(3)
            .map { day in
                DaySection(day: day, items: Array(byDay[day]!.prefix(2)))
            }
    }
}
