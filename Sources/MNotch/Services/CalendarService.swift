import EventKit
import Observation

/// Today's events via EventKit. Access is requested lazily, the first time the
/// calendar tab appears, so launch never triggers a TCC prompt.
@MainActor
@Observable
final class CalendarService {
    struct Item: Identifiable, Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let colorRed: Double
        let colorGreen: Double
        let colorBlue: Double
    }

    private(set) var items: [Item] = []
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
        let calendar = Calendar.current
        let now = Date()
        let endOfDay = calendar.date(
            byAdding: .day, value: 1, to: calendar.startOfDay(for: now)
        ) ?? now
        let predicate = store.predicateForEvents(
            withStart: now, end: endOfDay, calendars: nil
        )
        items = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
            .prefix(5)
            .map { event in
                let color = event.calendar?.cgColor?.components ?? [0.5, 0.5, 1, 1]
                return Item(
                    id: event.eventIdentifier ?? UUID().uuidString,
                    title: event.title ?? "Untitled",
                    start: event.startDate,
                    end: event.endDate,
                    colorRed: Double(color.count > 0 ? color[0] : 0.5),
                    colorGreen: Double(color.count > 1 ? color[1] : 0.5),
                    colorBlue: Double(color.count > 2 ? color[2] : 1)
                )
            }
    }
}
