import XCTest
@testable import Mila

@MainActor
final class SharedFolderSyncTests: XCTestCase {
    private let then = Date(timeIntervalSince1970: 1_700_000_000)

    func test_a_new_teammate_bundle_is_imported() {
        XCTAssertTrue(SharedFolderSync.shouldImport(isMine: false, localExists: false, localTrashed: false,
                                                    lastImported: nil, modified: then))
    }

    func test_my_own_bundle_is_never_imported() {
        XCTAssertFalse(SharedFolderSync.shouldImport(isMine: true, localExists: true, localTrashed: false,
                                                     lastImported: nil, modified: then))
    }

    func test_an_updated_bundle_is_imported_again_and_an_unchanged_one_is_not() {
        XCTAssertTrue(SharedFolderSync.shouldImport(isMine: false, localExists: true, localTrashed: false,
                                                    lastImported: then, modified: then.addingTimeInterval(60)))
        XCTAssertFalse(SharedFolderSync.shouldImport(isMine: false, localExists: true, localTrashed: false,
                                                     lastImported: then, modified: then))
    }

    func test_a_teammate_recording_the_user_deleted_stays_deleted() {
        XCTAssertFalse(SharedFolderSync.shouldImport(isMine: false, localExists: false, localTrashed: false,
                                                     lastImported: then, modified: then.addingTimeInterval(60)))
        XCTAssertFalse(SharedFolderSync.shouldImport(isMine: false, localExists: true, localTrashed: true,
                                                     lastImported: then, modified: then.addingTimeInterval(60)))
    }

    func test_bundle_file_names_round_trip_and_others_are_ignored() {
        let id = UUID()
        let dir = URL(fileURLWithPath: "/tmp/shared", isDirectory: true)
        let url = SharedFolderSync.bundleURL(for: id, in: dir)
        XCTAssertEqual(SharedFolderSync.bundleID(fromFileName: url.lastPathComponent), id)
        XCTAssertNil(SharedFolderSync.bundleID(fromFileName: "Weekly sync.milashare"))
        XCTAssertNil(SharedFolderSync.bundleID(fromFileName: "\(id.uuidString).md"))
        XCTAssertNil(SharedFolderSync.bundleID(fromFileName: ".\(id.uuidString).milashare.partial"))
    }

    func test_note_carries_summary_attendees_and_full_transcript() {
        let rec = Recording(title: "Payments POC", source: .meeting, audioFileName: "a.m4a",
                            status: .completed, fullText: "hello there", summary: "We agreed.",
                            calendarEvent: CalendarEvent(title: "Payments POC", start: then, end: then,
                                                         attendees: [.init(name: "Ada", email: nil),
                                                                     .init(name: nil, email: "bob@example.com")]))
        let note = SharedFolderSync.note(for: rec)
        XCTAssertTrue(note.hasPrefix("# Payments POC\n"))
        XCTAssertTrue(note.contains("We agreed."))
        XCTAssertTrue(note.contains("Attendees: Ada, bob@example.com"))
        XCTAssertTrue(note.contains("## Transcript\n\nhello there"))
    }

    func test_fingerprint_changes_with_what_teammates_see_only() {
        var rec = Recording(title: "A", source: .meeting, audioFileName: "a.m4a", status: .completed,
                            fullText: "x", folder: "Team")
        let before = SharedFolderSync.fingerprint(rec)
        rec.folder = "Elsewhere"   // local filing: not shared
        XCTAssertEqual(SharedFolderSync.fingerprint(rec), before)
        rec.title = "B"
        XCTAssertNotEqual(SharedFolderSync.fingerprint(rec), before)
    }
}
