import AppKit
import SwiftUI

/// The one thing SwiftUI cannot express: refusing to quit.
///
/// Spec §Core pipeline 1 — "confirm dialog guards against quitting mid-recording".
/// Quitting while recording is not merely inconvenient: an AAC `.m4a` is only
/// playable once its `moov` atom is written, which happens when the source
/// finalizes the file. A process killed mid-capture leaves an unplayable file,
/// so confirming to quit *stops the recording first* and only then terminates.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppQuitGuard.isRecording else { return .terminateNow }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Stop recording and quit?"
        alert.informativeText = """
            A recording is in progress. Quitting stops it and saves everything captured \
            so far to your library.
            """
        alert.addButton(withTitle: "Stop and Quit")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return .terminateCancel
        }

        // Finalizing the file is async, so hold termination until it is done.
        Task {
            await AppQuitGuard.finishRecording()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// The bridge from the app delegate — which SwiftUI instantiates outside the
/// `AppServices` object graph — to the live recording session.
@MainActor
enum AppQuitGuard {

    /// Set by ``AppServices`` at launch. Weak: the guard must never be the
    /// reason a session stays alive.
    static weak var recorder: RecordingSessionModel?

    static var isRecording: Bool { recorder?.isActive ?? false }

    /// Stops and saves the in-progress recording.
    static func finishRecording() async {
        await recorder?.stopForQuit()
    }
}
