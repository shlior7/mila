import Foundation

/// The vocabulary hint handed to whisper (`TranscribingEngine.transcribe(…prompt:)`):
/// the meeting's title and attendees, then the user's glossary (Settings →
/// Models → Vocabulary). Whisper spells what it has seen in the prompt, so
/// "brain.yaml" stops coming out as "brain yammer" and a colleague's name
/// stops being guessed phonetically.
enum VocabularyPrompt {
    static let glossaryDefaultsKey = "transcription.vocabulary"

    /// The prompt is carried into every 30 s window and shares whisper's
    /// ~224-token prompt budget with the text decoded so far. Hebrew runs
    /// at roughly a token per two characters, so this keeps the hint to
    /// well under half the budget.
    /// ponytail: character cap, not a token count; tokenize with
    /// `whisper_tokenize` if prompts get truncated in practice.
    static let maxCharacters = 240

    /// nil when there is nothing to hint.
    static func make(glossary: String, event: CalendarEvent?) -> String? {
        var parts: [String] = []
        if let title = event?.title.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            parts.append(title)
        }
        let names = (event?.attendees ?? []).compactMap { $0.name?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        parts += names
        parts += glossary.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Whole terms only: a name cut in half would teach whisper a wrong spelling.
        var out = ""
        for part in parts {
            let next = out.isEmpty ? part : out + ", " + part
            if next.count > maxCharacters { break }
            out = next
        }
        return out.isEmpty ? nil : out + "."
    }
}
