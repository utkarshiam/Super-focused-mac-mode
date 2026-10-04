import EventKit
import SwiftUI

/// Optional: reads calendar events so the Calendar view can show meetings next to tasks.
@MainActor
final class CalendarService: ObservableObject {
    static let shared = CalendarService()

    struct Event: Identifiable, Hashable {
        var id: String
        var title: String
        var start: Date
        var end: Date
        var isAllDay: Bool
        var calendarName: String
    }

    @Published private(set) var events: [Event] = []
    @Published private(set) var status: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)

    private let eventStore = EKEventStore()
    private var observer: NSObjectProtocol?
    private var range: (start: Date, end: Date)?

    var hasAccess: Bool {
        if #available(macOS 14.0, *) { return status == .fullAccess }
        return status.rawValue == 3 // .authorized
    }

    var isDenied: Bool { status == .denied || status == .restricted }

    func start() {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: eventStore, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func requestAccess() async -> Bool {
        do {
            if #available(macOS 14.0, *) {
                _ = try await eventStore.requestFullAccessToEvents()
            } else {
                _ = try await eventStore.requestAccess(to: .event)
            }
        } catch {
            NSLog("Docket: calendar access failed: \(error)")
        }
        status = EKEventStore.authorizationStatus(for: .event)
        refresh()
        return hasAccess
    }

    /// Makes sure events between the two days are loaded (the Calendar view calls this as you navigate).
    func ensure(from start: Date, to end: Date) {
        if let r = range, r.start <= start, r.end >= end { return }
        let cal = Calendar.current
        let lower = min(start, range?.start ?? start)
        let upper = max(end, range?.end ?? end)
        range = (cal.startOfDay(for: lower), cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: upper))!)
        refresh()
    }

    func refresh() {
        status = EKEventStore.authorizationStatus(for: .event)
        guard Prefs.useCalendar, hasAccess else {
            if !events.isEmpty { events = [] }
            return
        }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let r = range ?? (cal.date(byAdding: .day, value: -42, to: today)!, cal.date(byAdding: .day, value: 90, to: today)!)
        range = r
        let predicate = eventStore.predicateForEvents(withStart: r.start, end: r.end, calendars: nil)
        events = eventStore.events(matching: predicate)
            .filter { e in
                let me = e.attendees?.first { $0.isCurrentUser }
                return me?.participantStatus != .declined
            }
            .map {
                Event(id: ($0.eventIdentifier ?? UUID().uuidString) + "\($0.startDate.timeIntervalSince1970)",
                      title: $0.title ?? "Event", start: $0.startDate, end: $0.endDate,
                      isAllDay: $0.isAllDay, calendarName: $0.calendar.title)
            }
            .sorted { $0.start < $1.start }
    }

    /// Events that touch `day` (multi-day events show on each day they cover).
    func events(on day: Date) -> [Event] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        return events.filter { $0.start < end && $0.end > start }
    }
}
