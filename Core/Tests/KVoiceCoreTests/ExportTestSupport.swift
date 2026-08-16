import Foundation

@testable import KVoiceCore

// MARK: - Document fixtures

enum ExportFixture {

    /// Exports are rendered in a fixed zone so golden files do not change with
    /// the machine's region settings.
    static let utc = TimeZone(secondsFromGMT: 0)!

    /// Builds a date from wall-clock parts in `timeZone`.
    static func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int = 0,
        _ minute: Int = 0,
        _ second: Int = 0,
        timeZone: TimeZone = utc
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(
            year: year, month: month, day: day,
            hour: hour, minute: minute, second: second
        )
        return calendar.date(from: components)!
    }

    /// A two-speaker meeting that alternates and comes back to the first
    /// speaker, with a turn past the one-hour mark and an apostrophe in the
    /// text — enough to exercise grouping, hour-wide timestamps and escaping.
    static var meeting: TranscriptDocument {
        TranscriptDocument(
            title: "Weekly sync",
            date: date(2026, 8, 13, 14, 30),
            utterances: [
                .init(speaker: "Alice", startMs: 5_000, text: "Morning, everyone."),
                .init(speaker: "Alice", startMs: 9_400, text: "Let's start with the roadmap."),
                .init(speaker: "Bob", startMs: 72_000, text: "Morning."),
                .init(speaker: "Alice", startMs: 3_723_000, text: "Wrapping up.")
            ]
        )
    }

    static func utterance(_ speaker: String, _ startMs: Int, _ text: String) -> TranscriptDocument.Utterance {
        TranscriptDocument.Utterance(speaker: speaker, startMs: startMs, text: text)
    }

    /// A single-turn document, for tests that care about one specific string.
    static func document(
        title: String = "Test",
        text: String,
        speaker: String = "Alice"
    ) -> TranscriptDocument {
        TranscriptDocument(
            title: title,
            date: date(2026, 8, 13, 14, 30),
            utterances: [utterance(speaker, 0, text)]
        )
    }
}
