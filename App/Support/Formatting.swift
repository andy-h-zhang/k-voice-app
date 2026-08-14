import AppKit
import Foundation
import KVoiceCore

/// Display formatting for the app layer.
///
/// Clock times come from `TimestampFormatter` in Core rather than a second
/// implementation here — the transcript editor and the exports show the same
/// `hh:mm:ss`, and there is no reason for the library to disagree with them.
enum Display {

    /// `hh:mm:ss` — always three fields, for the live elapsed readout where a
    /// field appearing mid-recording would make the digits jump.
    static func elapsed(_ seconds: TimeInterval) -> String {
        TimestampFormatter.clockTime(milliseconds: Int((seconds * 1000).rounded()))
    }

    /// Compact duration for list rows: `4:07`, or `1:04:07` past an hour.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// Date for list rows: "Today at 15:04", "Yesterday at 09:12", "13 Aug 2026 at 15:04".
    static func rowDate(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today at \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday at \(time)" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// The Finder side of "files are user-visible" (spec §Library).
enum FinderIntegration {

    /// Selects the item in a Finder window.
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Opens the folder itself.
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Opens System Settings at Privacy & Security ▸ Microphone.
    static func openMicrophoneSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
