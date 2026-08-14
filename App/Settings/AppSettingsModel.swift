import AppKit
import Foundation
import KVoiceCore
import Observation

/// State behind the Settings scene.
///
/// Most settings are a value in `UserDefaults` and need no model at all. Three
/// do:
///
/// - the **input device list**, which is a CoreAudio query that can fail and
///   whose answer changes when hardware is plugged in;
/// - the **keyterms editor**, whose draft text is not the same shape as the
///   stored array and has to be checked against AssemblyAI's limits as it is
///   typed;
/// - the **storage folder move**, which touches every file the app owns and
///   therefore has preconditions, an error surface, and an aftermath.
///
/// It is owned by ``AppServices`` rather than by the view because the aftermath
/// of a move — "the library has moved; relaunch" — has to outlive the Settings
/// window being closed.
@MainActor
@Observable
final class AppSettingsModel {

    // MARK: - Input devices

    /// Which input the recorder should use.
    enum InputChoice: Hashable {
        case systemDefault
        case device(uid: String)
    }

    private(set) var inputDevices: [AudioInputDevice] = []

    /// Set when the device list could not be read at all.
    private(set) var deviceError: String?

    // MARK: - Mirrored settings
    //
    // `SettingsStore` is a `UserDefaults` wrapper, not an `@Observable`. A
    // control bound straight through a computed property that reads it would
    // write the new value correctly and then **never redraw** — the slider's
    // own number, the "recording will use" line, and the export picker would
    // all keep showing the old value. So each editable setting is mirrored into
    // observable storage here, and written through by an explicit setter that
    // reads the stored value back (which is also how the threshold's clamping
    // becomes visible).

    private(set) var similarityThreshold: Float
    private(set) var defaultExportFormat: ExportFormat
    private(set) var inputChoice: InputChoice
    private(set) var libraryRoot: URL

    // MARK: - Keyterms

    /// The editor's text, one term per line. The draft is authoritative while
    /// the field has focus — settings are written *from* it and never read back
    /// into it, so trimming and de-duplication on save can't rewrite a line the
    /// user is still typing.
    var keytermsText: String = ""

    // MARK: - Storage folder

    /// Set after a successful move: the library is somewhere new and this
    /// process is still pointed at the old place.
    private(set) var pendingRelaunchPath: String?

    /// Surfaced as an alert in Settings.
    var errorMessage: String?

    /// Confirmation for a move that worked.
    private(set) var moveSummary: String?

    /// Why a move must not start right now, or nil when it may. Wired by
    /// ``AppServices`` to the recorder and the running-jobs set.
    @ObservationIgnored
    var busyReason: (() -> String?)?

    // MARK: - Dependencies

    let settings: SettingsStore
    private var store: RecordingStore

    init(settings: SettingsStore, store: RecordingStore) {
        self.settings = settings
        self.store = store
        self.keytermsText = settings.keyterms.joined(separator: "\n")
        self.similarityThreshold = settings.similarityThreshold
        self.defaultExportFormat = settings.defaultExportFormat
        self.inputChoice = settings.inputDeviceUID.map { .device(uid: $0) } ?? .systemDefault
        self.libraryRoot = settings.storageFolderURL
    }

    // MARK: - Devices

    /// Re-reads the connected input devices. Cheap, and needs no microphone
    /// permission — only capturing does.
    func refreshInputDevices() {
        do {
            inputDevices = try AudioDeviceManager.inputDevices()
            deviceError = nil
        } catch {
            inputDevices = []
            deviceError = Self.describe(error)
        }
    }

    /// Selects an input. Takes effect on the next recording and the next
    /// enrollment, both of which read the UID when they start.
    func setInputChoice(_ choice: InputChoice) {
        switch choice {
        case .systemDefault: settings.inputDeviceUID = nil
        case .device(let uid): settings.inputDeviceUID = uid
        }
        inputChoice = choice
    }

    /// UID of the selected device, or nil when following the system default.
    var selectedDeviceUID: String? {
        if case .device(let uid) = inputChoice { return uid }
        return nil
    }

    /// The chosen device's UID when it is no longer connected.
    ///
    /// Kept visible in the picker rather than silently falling back to the
    /// default: a user who unplugs an interface should be told their choice is
    /// missing, not quietly recorded on the built-in microphone.
    var missingDeviceUID: String? {
        guard let uid = selectedDeviceUID else { return nil }
        return inputDevices.contains { $0.uid == uid } ? nil : uid
    }

    /// Name of the device recording will actually use right now.
    var effectiveDeviceName: String {
        if let uid = selectedDeviceUID {
            if let device = inputDevices.first(where: { $0.uid == uid }) {
                return device.name
            }
            return "Not connected — recording will fail until it is plugged back in"
        }
        if let fallback = inputDevices.first(where: \.isDefault) {
            return "\(fallback.name) (system default)"
        }
        return "No input device"
    }

    // MARK: - Threshold

    /// Writes the threshold and reads back what the store kept, so the clamp to
    /// `SettingsStore.thresholdRange` is visible rather than silent.
    func setSimilarityThreshold(_ value: Float) {
        settings.similarityThreshold = value
        similarityThreshold = settings.similarityThreshold
    }

    /// What moving the slider trades off, in the user's terms.
    var thresholdExplanation: String {
        switch similarityThreshold {
        case ..<0.55:
            return """
                Lenient. Speakers get named more readily, including some who are only a \
                rough match — expect the occasional wrong name to fix in the transcript.
                """
        case ..<0.68:
            return """
                Balanced — the tuned default. Most known speakers are named automatically, \
                and a voice that is genuinely unfamiliar is flagged as unknown rather than \
                guessed at.
                """
        default:
            return """
                Strict. Only close matches get a name, so mistakes are rare — but familiar \
                people will more often come back as “Unknown Speaker” for you to confirm.
                """
        }
    }

    var isThresholdDefault: Bool {
        abs(similarityThreshold - ClusterMatcher.defaultThreshold) < 0.005
    }

    func resetThreshold() {
        setSimilarityThreshold(ClusterMatcher.defaultThreshold)
    }

    // MARK: - Export

    func setDefaultExportFormat(_ format: ExportFormat) {
        settings.defaultExportFormat = format
        defaultExportFormat = format
    }

    // MARK: - Keyterms

    /// What AssemblyAI will actually accept from the current draft.
    var keytermReport: KeytermReport {
        KeytermReport(text: keytermsText)
    }

    /// Persists the draft. Called as it is edited: a job takes a settings
    /// snapshot when it is submitted, so a saved value is in force for the next
    /// transcription without a relaunch, and cannot change one already running.
    func commitKeyterms() {
        settings.keyterms = KeytermReport.lines(in: keytermsText)
    }

    // MARK: - Storage folder

    /// Asks for a destination and moves the whole library there.
    func chooseStorageFolder() {
        if let reason = busyReason?() {
            errorMessage = """
                The library can't move while \(reason). Wait for it to finish and try again — \
                moving files out from under a recording or a transcription would corrupt it.
                """
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Move Library Here"
        panel.message = """
            Choose an empty or brand-new folder. KVoice moves every recording, every \
            transcript, and its database there.
            """
        panel.directoryURL = libraryRoot.deletingLastPathComponent()

        guard panel.runModal() == .OK, let destination = panel.url else { return }
        move(to: destination)
    }

    /// The move itself, separated from the panel so the rules are readable.
    func move(to destination: URL) {
        let previous = store.rootURL
        do {
            let moved = try store.moveRoot(to: destination)
            store = moved
            // Settings only change once the files have actually moved: a
            // pointer to a folder the library is not in would be worse than
            // not moving at all.
            settings.storageFolderURL = moved.rootURL
            libraryRoot = moved.rootURL

            moveSummary = """
                Your library is now at \(moved.rootURL.path). The old folder \
                (\(previous.path)) has been left behind, empty — you can delete it.
                """
            pendingRelaunchPath = moved.rootURL.path
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    func dismissMoveSummary() {
        moveSummary = nil
    }

    /// Restarts the app so it opens the database at its new location.
    ///
    /// Reopening a `ModelContainer` in place is not offered: it is built once
    /// at launch (`AppBootstrap`) and handed to a dozen objects that hold it
    /// for the life of the process, so swapping it underneath them would be a
    /// far bigger change than a relaunch — and a relaunch is a second.
    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    func revealLibrary() {
        FinderIntegration.open(libraryRoot)
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

// MARK: - Keyterms

/// What the keyterms draft becomes once AssemblyAI's limits are applied.
///
/// The limits are real and silent on the server side (`AssemblyAIConstants`,
/// verified in `docs/api-notes.md`): a term of more than six words is ignored,
/// and the whole list is capped by a total *word* budget. Showing the arithmetic
/// as it is typed is the difference between "my terms aren't working" and "term
/// 41 is past the budget".
struct KeytermReport {

    /// Total word budget. Taken from the models actually sent, which include
    /// `universal-2` as a fallback — and its budget is the lower of the two, so
    /// it is the one that binds.
    static let wordBudget = TranscriptRequest.keytermWordBudget(
        for: AssemblyAIConstants.defaultSpeechModels
    )

    /// Non-empty lines, trimmed — what the user thinks they typed.
    let entered: [String]
    /// Terms of more than `maxWordsPerKeyterm` words. Dropped by the API.
    let tooLong: [String]
    /// Repeats of an earlier term, case-insensitively. Dropped.
    let duplicateCount: Int
    /// Terms that fit the rules but fall past the word budget. Dropped.
    let overBudgetCount: Int
    /// Exactly what will be sent as `keyterms_prompt`.
    let accepted: [String]
    /// Words the accepted terms consume.
    let wordsUsed: Int

    init(text: String) {
        let lines = Self.lines(in: text)
        entered = lines

        tooLong = lines.filter { $0.split(whereSeparator: \.isWhitespace).count > AssemblyAIConstants.maxWordsPerKeyterm }

        var seen = Set<String>()
        var duplicates = 0
        var eligible: [String] = []
        for term in lines where !tooLong.contains(term) {
            if seen.insert(term.lowercased()).inserted {
                eligible.append(term)
            } else {
                duplicates += 1
            }
        }
        duplicateCount = duplicates

        let kept = TranscriptRequest.sanitizedKeyterms(lines, wordBudget: Self.wordBudget)
        accepted = kept
        overBudgetCount = max(0, eligible.count - kept.count)
        wordsUsed = kept.reduce(0) { $0 + $1.split(whereSeparator: \.isWhitespace).count }
    }

    static func lines(in text: String) -> [String] {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var hasProblems: Bool {
        !tooLong.isEmpty || duplicateCount > 0 || overBudgetCount > 0
    }

    var isOverBudget: Bool { wordsUsed >= Self.wordBudget }

    /// One line summarizing every drop, or nil when nothing was dropped.
    var problemSummary: String? {
        guard hasProblems else { return nil }
        var parts: [String] = []
        if !tooLong.isEmpty {
            parts.append(
                """
                \(tooLong.count) term\(tooLong.count == 1 ? " is" : "s are") longer than \
                \(AssemblyAIConstants.maxWordsPerKeyterm) words
                """
            )
        }
        if duplicateCount > 0 {
            parts.append("\(duplicateCount) repeated")
        }
        if overBudgetCount > 0 {
            parts.append("\(overBudgetCount) past the \(Self.wordBudget)-word budget")
        }
        return "Ignored: " + parts.joined(separator: ", ") + "."
    }
}
