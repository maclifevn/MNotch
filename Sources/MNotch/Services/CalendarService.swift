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
        let calendarID: String
        let colorRed: Double
        let colorGreen: Double
        let colorBlue: Double
    }

    /// A timed event is happening right now.
    var hasOngoingEvent: Bool {
        let now = Date()
        return today.contains { !$0.isAllDay && $0.start <= now && $0.end > now }
    }

    /// Next event for the compact idle chrome (calendars set to
    /// notifications-only are excluded here).
    var nextEvent: Item? {
        let now = Date()
        let settings = SettingsStore.shared
        func usable(_ item: Item) -> Bool {
            settings.use(for: item.calendarID) != .notifications
        }
        return today.first { !$0.isAllDay && $0.end > now && usable($0) }
            ?? today.first(where: usable)
            ?? upcoming.first?.items.first(where: usable)
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
    /// Day numbers of the current month that have events (for the mini grid).
    private(set) var monthEventDays: Set<Int> = []
    private(set) var authorized = false
    private(set) var requested = false

    /// Quick Peek: (event, isStartingNow).
    @ObservationIgnored var onPeek: ((Item, Bool) -> Void)?
    @ObservationIgnored var onChime: (() -> Void)?

    @ObservationIgnored private var store: EKEventStore?
    @ObservationIgnored private var peekTimers: [Timer] = []
    @ObservationIgnored private var chimeTimer: Timer?

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
            // Keep peeks/idle fresh as time passes.
            let refresh = Timer(timeInterval: 600, repeats: true) { _ in
                Task { @MainActor in self?.reload() }
            }
            refresh.tolerance = 60
            RunLoop.main.add(refresh, forMode: .common)
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
                    calendarID: event.calendar?.calendarIdentifier ?? "",
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

        reloadMonthDays(store: store, calendars: enabledCalendars)
        schedulePeeks()
        scheduleChime()
    }

    private func reloadMonthDays(store: EKEventStore, calendars: [EKCalendar]) {
        let cal = Calendar.current
        guard let interval = cal.dateInterval(of: .month, for: Date()) else { return }
        let predicate = store.predicateForEvents(
            withStart: interval.start,
            end: interval.end,
            calendars: calendars.isEmpty ? nil : calendars
        )
        monthEventDays = Set(
            store.events(matching: predicate).map { cal.component(.day, from: $0.startDate) }
        )
    }

    // MARK: - Quick Peek & chime

    private func schedulePeeks() {
        peekTimers.forEach { $0.invalidate() }
        peekTimers = []

        let settings = SettingsStore.shared
        guard settings.calendarEnabled, settings.calendarQuickPeek else { return }

        let now = Date()
        let peekable = today.filter { item in
            !item.isAllDay
                && item.start > now
                && settings.use(for: item.calendarID) != .activity
        }.prefix(3)

        for item in peekable {
            if settings.calendarPeekBeforeStart {
                let fireAt = item.start.addingTimeInterval(-settings.calendarTimeBefore * 60)
                if fireAt > now {
                    schedulePeek(at: fireAt, item: item, starting: false)
                }
            }
            if settings.calendarPeekWhenStarting {
                schedulePeek(at: item.start, item: item, starting: true)
            }
        }
    }

    private func schedulePeek(at date: Date, item: Item, starting: Bool) {
        let timer = Timer(fire: date, interval: 0, repeats: false) { _ in
            Task { @MainActor [weak self] in
                self?.onPeek?(item, starting)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        peekTimers.append(timer)
    }

    private func scheduleChime() {
        chimeTimer?.invalidate()
        chimeTimer = nil
        guard SettingsStore.shared.calendarHourlyChime else { return }

        let cal = Calendar.current
        guard let nextHour = cal.nextDate(
            after: Date(),
            matching: DateComponents(minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) else { return }

        let timer = Timer(fire: nextHour, interval: 3600, repeats: true) { _ in
            Task { @MainActor [weak self] in
                guard SettingsStore.shared.calendarHourlyChime else { return }
                self?.onChime?()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        chimeTimer = timer
    }
}
