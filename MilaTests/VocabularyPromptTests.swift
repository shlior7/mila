import XCTest
@testable import Mila

final class VocabularyPromptTests: XCTestCase {
    private let event = CalendarEvent(title: "Payments POC kickoff", start: Date(), end: Date(),
                                      attendees: [.init(name: "Ada Lovelace", email: "ada@example.com"),
                                                  .init(name: nil, email: "room@example.com")])

    func test_title_then_attendee_names_then_glossary() {
        XCTAssertEqual(VocabularyPrompt.make(glossary: "CDD, brain.yaml\nKyber", event: event),
                       "Payments POC kickoff, Ada Lovelace, CDD, brain.yaml, Kyber.")
    }

    func test_nothing_to_hint_is_nil() {
        XCTAssertNil(VocabularyPrompt.make(glossary: " , \n", event: nil))
    }

    func test_long_glossary_is_cut_at_a_whole_term() {
        let terms = (1...100).map { "term\($0)" }.joined(separator: ", ")
        let prompt = try! XCTUnwrap(VocabularyPrompt.make(glossary: terms, event: nil))
        XCTAssertLessThanOrEqual(prompt.count, VocabularyPrompt.maxCharacters + 1)
        XCTAssertTrue(prompt.hasSuffix("."))
        XCTAssertFalse(prompt.dropLast().split(separator: ",").last!.trimmingCharacters(in: .whitespaces).isEmpty)
        XCTAssertTrue(prompt.hasPrefix("term1, term2"))
    }
}
