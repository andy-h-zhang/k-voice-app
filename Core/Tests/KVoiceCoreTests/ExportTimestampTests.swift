import Foundation
import Testing

@testable import KVoiceCore

/// Timestamp formatting. Meetings routinely run past an hour, so the invariant
/// that matters is that hours are always present and never wrap.
@Suite("Export timestamps")
struct ExportTimestampTests {

    // MARK: - Clock time

    @Test("zero is a full hh:mm:ss")
    func zero() {
        #expect(TimestampFormatter.clockTime(milliseconds: 0) == "00:00:00")
    }

    @Test("seconds, minutes and hours each roll over correctly")
    func fields() {
        #expect(TimestampFormatter.clockTime(milliseconds: 1_000) == "00:00:01")
        #expect(TimestampFormatter.clockTime(milliseconds: 59_000) == "00:00:59")
        #expect(TimestampFormatter.clockTime(milliseconds: 60_000) == "00:01:00")
        #expect(TimestampFormatter.clockTime(milliseconds: 3_599_000) == "00:59:59")
        #expect(TimestampFormatter.clockTime(milliseconds: 3_600_000) == "01:00:00")
        #expect(TimestampFormatter.clockTime(milliseconds: 3_723_000) == "01:02:03")
    }

    /// The reason the format is not `mm:ss`: a two-hour meeting's timestamps
    /// would be ambiguous, and the spec asks for `hh:mm:ss`.
    @Test("an hour-plus meeting reads as hours, not wrapped minutes")
    func longMeeting() {
        #expect(TimestampFormatter.clockTime(milliseconds: 2 * 3_600_000) == "02:00:00")
        #expect(TimestampFormatter.clockTime(milliseconds: 5_400_000) == "01:30:00")
    }

    @Test("the hours field grows past 99 rather than wrapping")
    func hoursDoNotWrap() {
        #expect(TimestampFormatter.clockTime(milliseconds: 359_999_000) == "99:59:59")
        #expect(TimestampFormatter.clockTime(milliseconds: 360_000_000) == "100:00:00")
    }

    /// Rounding up would point at a moment before the speaker started.
    @Test("sub-second remainders truncate")
    func truncatesMilliseconds() {
        #expect(TimestampFormatter.clockTime(milliseconds: 999) == "00:00:00")
        #expect(TimestampFormatter.clockTime(milliseconds: 1_999) == "00:00:01")
        #expect(TimestampFormatter.clockTime(milliseconds: 3_599_999) == "00:59:59")
    }

    @Test("a negative offset clamps to zero instead of formatting nonsense")
    func negativeClamps() {
        #expect(TimestampFormatter.clockTime(milliseconds: -1) == "00:00:00")
        #expect(TimestampFormatter.clockTime(milliseconds: -60_000) == "00:00:00")
    }

    @Test("the bracketed form is what turn headers use")
    func bracketed() {
        #expect(TimestampFormatter.bracketedClockTime(milliseconds: 3_723_000) == "[01:02:03]")
    }

    // MARK: - Document date

    @Test("the header date is ISO-style, 24-hour, zero-padded")
    func documentDate() {
        let date = ExportFixture.date(2026, 8, 13, 14, 30)

        #expect(TimestampFormatter.documentDate(date, timeZone: ExportFixture.utc) == "2026-08-13 14:30")
    }

    @Test("single-digit months, days and hours are padded")
    func documentDatePadding() {
        let date = ExportFixture.date(2026, 1, 2, 3, 4)

        #expect(TimestampFormatter.documentDate(date, timeZone: ExportFixture.utc) == "2026-01-02 03:04")
    }

    @Test("midnight and noon are unambiguous in 24-hour form")
    func documentDateHours() {
        #expect(
            TimestampFormatter.documentDate(ExportFixture.date(2026, 8, 13, 0, 0), timeZone: ExportFixture.utc)
                == "2026-08-13 00:00"
        )
        #expect(
            TimestampFormatter.documentDate(ExportFixture.date(2026, 8, 13, 12, 0), timeZone: ExportFixture.utc)
                == "2026-08-13 12:00"
        )
    }

    /// A meeting is remembered in the local wall-clock time it happened at.
    @Test("the date is rendered in the requested zone")
    func documentDateHonorsTimeZone() {
        let date = ExportFixture.date(2026, 8, 13, 23, 30)
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!

        #expect(TimestampFormatter.documentDate(date, timeZone: ExportFixture.utc) == "2026-08-13 23:30")
        #expect(TimestampFormatter.documentDate(date, timeZone: tokyo) == "2026-08-14 08:30")
    }
}
