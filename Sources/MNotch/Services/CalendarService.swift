import AppKit
import EventKit
import Observation

enum CalendarSourceSelection {
    static func enabledIdentifiers(
        available: [String],
        disabled: [String]
    ) -> [String] {
        let disabledSet = Set(disabled)
        return available.filter { !disabledSet.contains($0) }
    }
}

/// Own EventKit on a dedicated serial actor. `EKEventStore.events(matching:)`
/// is synchronous and can touch Calendar's database; running it on MainActor
/// made the first notch expansion and Settings changes visibly hitch on users
/// with large calendars.
private actor CalendarWorker {
    struct Snapshot: Sendable {
        let today: [CalendarService.Item]
        let upcoming: [CalendarService.DaySection]
        let calendars: [CalendarService.CalendarInfo]
        let monthEventDays: Set<Int>
    }

    private let store = EKEventStore()

    func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    func load(
        disabledCalendarIDs: [String],
        includeMonthDays: Bool,
        now: Date = Date()
    ) -> Snapshot {
        let allCalendars = store.calendars(for: .event)
        let calendarInfos = allCalendars.map { calendarInfo($0) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        let enabledIDs = Set(CalendarSourceSelection.enabledIdentifiers(
            available: allCalendars.map(\.calendarIdentifier),
            disabled: disabledCalendarIDs
        ))
        let enabledCalendars = allCalendars.filter {
            enabledIDs.contains($0.calendarIdentifier)
        }
        guard !enabledCalendars.isEmpty else {
            return Snapshot(
                today: [],
                upcoming: [],
                calendars: calendarInfos,
                monthEventDays: []
            )
        }

        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let startOfTomorrow = calendar.date(
            byAdding: .day, value: 1, to: startOfToday
        ) ?? now
        let windowEnd = calendar.date(
            byAdding: .day, value: 8, to: startOfToday
        ) ?? now
        let predicate = store.predicateForEvents(
            withStart: startOfToday,
            end: windowEnd,
            calendars: enabledCalendars
        )
        let events = store.events(matching: predicate)
            .sorted {
                if $0.isAllDay != $1.isAllDay { return $0.isAllDay }
                return $0.startDate < $1.startDate
            }
            .map(eventItem)

        let today = events.filter { $0.start < startOfTomorrow }
        let byDay = Dictionary(
            grouping: events.filter { $0.start >= startOfTomorrow }
        ) { calendar.startOfDay(for: $0.start) }
        let upcoming = byDay.keys.sorted()
            .prefix(3)
            .map { day in
                CalendarService.DaySection(
                    day: day,
                    items: Array((byDay[day] ?? []).prefix(2))
                )
            }

        var monthDays: Set<Int> = []
        if includeMonthDays,
           let interval = calendar.dateInterval(of: .month, for: now) {
            let monthPredicate = store.predicateForEvents(
                withStart: interval.start,
                end: interval.end,
                calendars: enabledCalendars
            )
            monthDays = Set(store.events(matching: monthPredicate).map {
                calendar.component(.day, from: $0.startDate)
            })
        }

        return Snapshot(
            today: today,
            upcoming: upcoming,
            calendars: calendarInfos,
            monthEventDays: monthDays
        )
    }

    private func calendarInfo(_ calendar: EKCalendar) -> CalendarService.CalendarInfo {
        let color = calendar.cgColor?.components ?? [0.6, 0.5, 1, 1]
        return CalendarService.CalendarInfo(
            id: calendar.calendarIdentifier,
            title: calendar.title,
            red: Double(color.count > 0 ? color[0] : 0.6),
            green: Double(color.count > 1 ? color[1] : 0.5),
            blue: Double(color.count > 2 ? color[2] : 1)
        )
    }

    private func eventItem(_ event: EKEvent) -> CalendarService.Item {
        let color = event.calendar?.cgColor?.components ?? [0.6, 0.5, 1, 1]
        let calendarID = event.calendar?.calendarIdentifier ?? ""
        let title = event.title ?? L10n.string("Untitled")
        let start = event.startDate ?? Date.distantPast
        let end = event.endDate ?? start
        // Some subscribed calendars expose no eventIdentifier. Derive a stable
        // identity so SwiftUI doesn't discard/recreate every event chip on each
        // refresh (the previous random UUID caused needless transitions).
        let fallbackID = "\(calendarID)|\(title)|\(start.timeIntervalSince1970)|\(end.timeIntervalSince1970)"
        return CalendarService.Item(
            id: event.eventIdentifier ?? fallbackID,
            title: title,
            start: start,
            end: end,
            isAllDay: event.isAllDay,
            calendarID: calendarID,
            colorRed: Double(color.count > 0 ? color[0] : 0.6),
            colorGreen: Double(color.count > 1 ? color[1] : 0.5),
            colorBlue: Double(color.count > 2 ? color[2] : 1)
        )
    }
}

/// Calendar events via EventKit: today's (including all-day — holidays and
/// birthdays are the events people actually see up here) plus the next week,
/// grouped by day. Access is requested lazily, the first time the calendar
/// tab appears, so launch never triggers a TCC prompt.
@MainActor
@Observable
final class CalendarService {
    struct Item: Identifiable, Equatable, Sendable {
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
            // All-day only — a timed event that already ended must not
            // resurface as "next" for the rest of the day.
            ?? today.first { $0.isAllDay && usable($0) }
            ?? upcoming.first?.items.first(where: usable)
    }

    struct DaySection: Identifiable, Equatable, Sendable {
        let day: Date
        let items: [Item]
        var id: Date { day }
    }

    struct CalendarInfo: Identifiable, Equatable, Sendable {
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

    @ObservationIgnored private var worker: CalendarWorker?
    @ObservationIgnored private var startToken: UUID?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var peekTimers: [Timer] = []
    @ObservationIgnored private var chimeTimer: Timer?
    @ObservationIgnored private var refreshTimer: Timer?
    @ObservationIgnored private var storeChangeObserver: NSObjectProtocol?

    func ensureStarted() {
        guard !requested else { return }
        requested = true
        let worker = CalendarWorker()
        let token = UUID()
        self.worker = worker
        startToken = token
        startTask = Task { [weak self] in
            let granted = await worker.requestAccess()
            // stop() (e.g. display sleep) or a newer ensureStarted() may have run
            // during the await; without this guard the observer + 600s timer
            // below would be installed after teardown and leak, one per race.
            guard let self, self.requested, self.startToken == token else { return }
            self.startTask = nil
            self.authorized = granted
            guard granted else { return }
            self.reload()
            self.storeChangeObserver = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.scheduleReload(after: .milliseconds(250)) }
            }
            // Keep peeks/idle fresh as time passes.
            let refresh = Timer(timeInterval: 600, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.reload() }
            }
            refresh.tolerance = 60
            RunLoop.main.add(refresh, forMode: .common)
            self.refreshTimer = refresh
        }
    }

    func stop() {
        if let storeChangeObserver {
            NotificationCenter.default.removeObserver(storeChangeObserver)
        }
        storeChangeObserver = nil
        startTask?.cancel()
        startTask = nil
        reloadTask?.cancel()
        reloadTask = nil
        startToken = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        peekTimers.forEach { $0.invalidate() }
        peekTimers = []
        chimeTimer?.invalidate()
        chimeTimer = nil
        worker = nil
        requested = false
        authorized = false
    }

    /// Rebuild event selection and timers after a Calendar setting changes.
    /// Safe before authorization; the first successful start performs a reload.
    func reconfigure() {
        guard requested, authorized else { return }
        scheduleReload(after: .milliseconds(250))
    }

    /// Driven by the "Calendar access needed" button. If the user hasn't been
    /// asked yet, show the system prompt; once they've decided, macOS won't ask
    /// again, so send them to System Settings where a denied grant can be
    /// flipped (returning to the app re-checks via permissionMayHaveChanged).
    func requestAccess() {
        if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
            // Activate first: a menu-bar (accessory) app that isn't frontmost
            // can fail to surface the EventKit permission prompt when it's
            // triggered from the non-activating notch panel.
            NSApp.activate()
            stop()
            ensureStarted()
        } else {
            SystemSettings.open(.calendars)
        }
    }

    /// TCC can be changed in System Settings while MNotch remains running.
    /// Recreate the EventKit store when the app becomes active so the Calendar
    /// tab recovers without a relaunch.
    func permissionMayHaveChanged() {
        let nowAuthorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        guard requested, nowAuthorized != authorized else { return }
        stop()
        if nowAuthorized {
            ensureStarted()
        } else {
            // Preserve the fact that Calendar UI has been requested so it
            // immediately shows the access-recovery state after revocation.
            requested = true
        }
    }

    func reload() {
        scheduleReload(after: .zero)
    }

    private func scheduleReload(after delay: Duration) {
        guard let worker, authorized else { return }
        reloadTask?.cancel()
        let token = startToken
        let disabled = SettingsStore.shared.calendarDisabledCalendars
        let includeMonthDays = SettingsStore.shared.calendarMonthView
        reloadTask = Task { [weak self] in
            if delay != .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            let snapshot = await worker.load(
                disabledCalendarIDs: disabled,
                includeMonthDays: includeMonthDays
            )
            guard !Task.isCancelled,
                  let self,
                  self.startToken == token,
                  self.worker != nil
            else { return }
            self.reloadTask = nil
            self.today = snapshot.today
            self.upcoming = snapshot.upcoming
            self.calendars = snapshot.calendars
            self.monthEventDays = snapshot.monthEventDays
            self.schedulePeeks()
            self.scheduleChime()
        }
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
