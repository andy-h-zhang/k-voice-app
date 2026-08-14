import Foundation

/// Time formatting shared by every export format (and, later, the transcript
/// editor's turn headers).
///
/// Both functions are locale-independent by design: exports are documents that
/// travel to other machines, and golden-file tests need output that does not
/// change with the developer's region settings. Neither uses `DateFormatter`,
/// which would also make thread-safe reuse awkward.
public enum TimestampFormatter {

    /// Formats a recording offset as `hh:mm:ss`.
    ///
    /// Hours are always present and never wrap: meetings run past 59:59, so
    /// `mm:ss` would be ambiguous, and a two-hour meeting must read `02:00:00`
    /// rather than `00:00`. Beyond 99 hours the field simply grows.
    ///
    /// Sub-second remainders are truncated, so a timestamp never rounds
    /// forward past the moment the speaker actually started. Negative offsets
    /// clamp to zero.
    public static func clockTime(milliseconds: Int) -> String {
        let totalSeconds = max(0, milliseconds) / 1_000
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    /// The bracketed form used in turn headers: `[hh:mm:ss]`.
    public static func bracketedClockTime(milliseconds: Int) -> String {
        "[\(clockTime(milliseconds: milliseconds))]"
    }

    /// Formats a recording's date for a document header: `yyyy-MM-dd HH:mm`.
    ///
    /// ISO-style and 24-hour to match the app's folder naming
    /// (`2026-08-13 Standup`, `docs/implementation-plan.md` §On-disk layout),
    /// and because it is unambiguous everywhere the exported file might land.
    ///
    /// - Parameter timeZone: The zone the wall-clock time is read in. Defaults
    ///   to the caller's — a meeting is remembered in local time.
    public static func documentDate(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(
            format: "%04d-%02d-%02d %02d:%02d",
            parts.year ?? 0,
            parts.month ?? 1,
            parts.day ?? 1,
            parts.hour ?? 0,
            parts.minute ?? 0
        )
    }
}
