import XCTest
@testable import Mila

final class CalendarEventTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func event(_ title: String, startsIn start: TimeInterval, lasts length: TimeInterval) -> CalendarEvent {
        CalendarEvent(title: title, start: now.addingTimeInterval(start),
                      end: now.addingTimeInterval(start + length), attendees: [])
    }

    func test_picks_the_event_in_progress() {
        let events = [event("Earlier", startsIn: -7200, lasts: 1800),
                      event("Now", startsIn: -600, lasts: 1800)]
        XCTAssertEqual(CalendarEvent.best(of: events, at: now)?.title, "Now")
    }

    func test_an_event_about_to_start_counts() {
        XCTAssertEqual(CalendarEvent.best(of: [event("Soon", startsIn: 240, lasts: 1800)], at: now)?.title, "Soon")
        XCTAssertNil(CalendarEvent.best(of: [event("Later", startsIn: 600, lasts: 1800)], at: now))
    }

    func test_the_next_meeting_wins_over_one_running_late() {
        let events = [event("Overrunning", startsIn: -1800, lasts: 2400),
                      event("Next", startsIn: 60, lasts: 1800)]
        XCTAssertEqual(CalendarEvent.best(of: events, at: now)?.title, "Next")
    }

    func test_an_ended_event_does_not_count() {
        XCTAssertNil(CalendarEvent.best(of: [event("Over", startsIn: -1800, lasts: 1800)], at: now))
    }
}
