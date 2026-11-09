import Foundation
import EventKit

/// The calendar event a recording was made during, captured from EventKit
/// when the recording starts (Settings → Meetings → "Name recordings from
/// your calendar"). Persisted on the row so the title, attendees and the
/// recurring series survive even after the event is edited or deleted in
/// Calendar. Mirrored in MilaKit's `StoredRecording` so MCP clients see
/// who was invited, not just who the diarizer heard.
struct CalendarEvent: Codable, Hashable {
    struct Attendee: Codable, Hashable {
        var name: String?
        var email: String?
    }

    var title: String
    var start: Date
    var end: Date
    /// People invited, rooms and resources excluded. Includes the user.
    var attendees: [Attendee]
    /// Shared by every occurrence of a recurring event (EventKit's
    /// `calendarItemExternalIdentifier`), so a weekly sync's recordings can
    /// be grouped. nil for one-off events.
    var seriesID: String?

    /// A recording started up to this long before an event counts as that
    /// event — people hit Record while the call is still connecting.
    static let earlyStart: TimeInterval = 5 * 60

    /// The event a recording started at `now` belongs to: one in progress
    /// (or about to start), preferring the one whose start is closest to
    /// `now`, so a meeting running over into the next one's slot loses to
    /// the next one.
    static func best(of candidates: [CalendarEvent], at now: Date) -> CalendarEvent? {
        candidates
            .filter { $0.start.addingTimeInterval(-earlyStart) <= now && now < $0.end }
            .min { abs($0.start.timeIntervalSince(now)) < abs($1.start.timeIntervalSince(now)) }
    }
}

extension CalendarEvent {
    init(_ event: EKEvent) {
        self.init(
            title: event.title ?? "",
            start: event.startDate,
            end: event.endDate,
            attendees: (event.attendees ?? [])
                .filter { $0.participantType == .person || $0.participantType == .unknown }
                .map { p in
                    // `url` is `mailto:someone@example.com` for invitees.
                    let email = p.url.scheme == "mailto" ? p.url.absoluteString.dropFirst(7).removingPercentEncoding : nil
                    return Attendee(name: p.name, email: email)
                },
            seriesID: event.hasRecurrenceRules ? event.calendarItemExternalIdentifier : nil
        )
    }
}

/// Reads the user's calendars. One `EKEventStore` for the app, as Apple
/// recommends — each one is expensive and caches independently.
@MainActor
enum CalendarLookup {
    private static let store = EKEventStore()

    static var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Ask for calendar access. Resolves immediately (with the stored
    /// answer) when the user already decided.
    static func requestAccess() async -> Bool {
        if isAuthorized { return true }
        return (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// The event a recording starting now belongs to, or nil when there is
    /// none, access was not granted, or the user declined the event.
    static func currentEvent(at now: Date = Date()) -> CalendarEvent? {
        guard isAuthorized else { return nil }
        // Look back far enough to catch a long event already in progress.
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-12 * 60 * 60),
                                                 end: now.addingTimeInterval(CalendarEvent.earlyStart),
                                                 calendars: nil)
        let candidates = store.events(matching: predicate)
            .filter { !$0.isAllDay && !declinedByUser($0) }
            .map(CalendarEvent.init)
        return CalendarEvent.best(of: candidates, at: now)
    }

    private static func declinedByUser(_ event: EKEvent) -> Bool {
        event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
    }
}
