import AppKit
import EventKit

struct CalendarEvent: Equatable, Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let color: NSColor
    let location: String?
    let joinURL: URL?
}

/// Reads your upcoming events with EventKit (asks for Calendar access the
/// first time you switch the feature on). Read-only.
@MainActor
final class CalendarService: ObservableObject {
    @Published private(set) var events: [CalendarEvent] = []
    @Published private(set) var access: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    /// The next event if it starts within 10 minutes (or is starting now).
    @Published private(set) var soonEvent: CalendarEvent?

    var onStartingSoon: ((CalendarEvent) -> Void)?

    private let store = EKEventStore()
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var alerted: Set<String> = []
    private var enabled = false

    var hasAccess: Bool { access == .fullAccess }

    func setEnabled(_ on: Bool) {
        enabled = on
        timer?.invalidate(); timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard on else { events = []; soonEvent = nil; return }

        if hasAccess {
            begin()
        } else {
            store.requestFullAccessToEvents { [weak self] _, _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.access = EKEventStore.authorizationStatus(for: .event)
                    if self.enabled && self.hasAccess { self.begin() }
                }
            }
        }
    }

    private func begin() {
        reload()
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func reload() {
        guard hasAccess else { return }
        let now = Date()
        let end = Calendar.current.date(byAdding: .hour, value: 36, to: now) ?? now
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3600), end: end, calendars: nil)
        events = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now && $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
            .prefix(8)
            .map { e in
                CalendarEvent(id: e.eventIdentifier ?? UUID().uuidString,
                              title: e.title ?? "Untitled",
                              start: e.startDate, end: e.endDate,
                              color: e.calendar.color ?? .systemBlue,
                              location: e.location?.isEmpty == false ? e.location : nil,
                              joinURL: Self.meetingURL(e))
            }
        tick()
    }

    private func tick() {
        let now = Date()
        let next = events.first { $0.end > now }
        let soon = next.flatMap { e -> CalendarEvent? in
            let until = e.start.timeIntervalSince(now)
            let lead = Double(AppSettings.shared.meetingLeadMinutes) * 60
            return (until <= lead && until > -2 * 60) ? e : nil
        }
        if soon != soonEvent { soonEvent = soon }

        // Pop a card once, about a minute before the event starts.
        for e in events where !alerted.contains(e.id) {
            let until = e.start.timeIntervalSince(now)
            if until <= 60 && until > -60 {
                alerted.insert(e.id)
                onStartingSoon?(e)
            }
        }
    }

    /// Finds a Zoom / Meet / Teams / Webex link in the event.
    private static func meetingURL(_ e: EKEvent) -> URL? {
        if let url = e.url, ["http", "https"].contains(url.scheme ?? "") { return url }
        let text = [e.location, e.notes].compactMap { $0 }.joined(separator: " ")
        let pattern = #"https://[^\s<>"]*(zoom\.us|meet\.google\.com|teams\.microsoft\.com|teams\.live\.com|webex\.com)[^\s<>"]*"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return URL(string: String(text[range]))
    }
}
