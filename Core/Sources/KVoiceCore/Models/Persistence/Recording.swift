import Foundation
import SwiftData

/// A recording in the library — plan §1's `Recording` row.
///
/// The database follows the filesystem, never the other way round: the audio,
/// the verbatim API response, and the exports live in a user-visible folder
/// (`RecordingStore`), and this row stores *relative* names plus the state
/// machine's position. That keeps the store valid when the user moves the
/// library root in Settings, and keeps Finder and the library from disagreeing
/// (plan §3 decision 6).
///
/// ## What is and is not persisted
///
/// - **Utterances are rows** (`utterances`), because the editor edits them.
/// - **Words are not** (plan §3 decision 5): ~9k rows per hour of audio for a
///   feature v1 does not have. `rawResponseFile` is the word-level source.
/// - **The raw response is a file**, not a column, so it stays greppable next
///   to the audio and can rebuild this row from scratch (`reprocess`).
@Model
public final class Recording {

    /// Stable identity. Paths change (rename); this does not.
    public var id: UUID

    /// User-facing title. Renaming drives `RecordingStore.rename`, which moves
    /// the folder and files *first*; this is updated only after that succeeds.
    public var title: String

    /// Folder name under the library root, e.g. `2026-08-13 Standup`.
    public var folderName: String

    /// Audio file name inside that folder, e.g. `2026-08-13 Standup.m4a`.
    public var audioFileName: String

    public var createdAt: Date

    /// Audio length in seconds, probed from the finished file.
    public var durationSec: Double

    // MARK: - State machine (see `RecordingStatus`)

    /// Persisted discriminant of `status`. Stored raw so `#Predicate` can
    /// filter on it — SwiftData cannot see through computed properties.
    public var statusKindRaw: String

    /// Human-readable reason, non-nil only while `statusKind == .failed`.
    public var failureMessage: String?

    /// When the status last changed. Drives "stuck job" diagnostics and
    /// orders the resume queue on relaunch.
    public var statusChangedAt: Date

    // MARK: - Transcription bookkeeping

    /// The provider's transcript id, persisted as soon as the job is created.
    ///
    /// This is the whole resume story: on relaunch a mid-flight recording
    /// re-polls **this id** instead of re-uploading a 2-hour file.
    public var assemblyTranscriptId: String?

    /// The `upload_url` the provider returned, if the audio was already
    /// uploaded. Lets a retry after a rejected *submit* skip the upload, and
    /// lets a resubmit (after a terminal provider error, which pins to the old
    /// transcript id forever) reuse the bytes already on their side.
    public var uploadedAudioURLString: String?

    /// Path of the verbatim response, relative to the recording's folder
    /// (`transcript.raw.json`). Set only once a `completed` body has landed,
    /// so its presence means "re-processable without a network".
    public var rawResponseFile: String?

    /// When the transcript reached `done`.
    public var completedAt: Date?

    /// Model the provider actually served the request with, echoed back.
    public var speechModelUsed: String?

    /// Detected language, e.g. `en_us`.
    public var languageCode: String?

    // MARK: - Relationships

    @Relationship(deleteRule: .cascade, inverse: \Utterance.recording)
    public var utterances: [Utterance]

    @Relationship(deleteRule: .cascade, inverse: \SpeakerSlot.recording)
    public var speakerSlots: [SpeakerSlot]

    public init(
        id: UUID = UUID(),
        title: String,
        folderName: String,
        audioFileName: String,
        createdAt: Date = Date(),
        durationSec: Double = 0,
        status: RecordingStatus = .recorded,
        statusChangedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.folderName = folderName
        self.audioFileName = audioFileName
        self.createdAt = createdAt
        self.durationSec = durationSec
        self.statusKindRaw = status.kind.rawValue
        self.failureMessage = status.failureMessage
        self.statusChangedAt = statusChangedAt
        self.assemblyTranscriptId = nil
        self.uploadedAudioURLString = nil
        self.rawResponseFile = nil
        self.completedAt = nil
        self.speechModelUsed = nil
        self.languageCode = nil
        self.utterances = []
        self.speakerSlots = []
    }

    // MARK: - Derived

    /// The state machine's position. Writing it keeps the two persisted
    /// columns and `statusChangedAt` in sync — always set the status through
    /// here (or `setStatus`), never by poking `statusKindRaw`.
    public var status: RecordingStatus {
        get {
            RecordingStatus(
                kind: RecordingStatus.Kind(rawValue: statusKindRaw) ?? .recorded,
                failureMessage: failureMessage
            )
        }
        set {
            statusKindRaw = newValue.kind.rawValue
            failureMessage = newValue.failureMessage
        }
    }

    /// Sets the status and stamps the transition time.
    public func setStatus(_ newValue: RecordingStatus, at date: Date = Date()) {
        status = newValue
        statusChangedAt = date
    }

    /// Where this recording's files live, given the (configurable) library root.
    public func folder(inRoot root: URL) -> RecordingFolder {
        let folderURL = root.appendingPathComponent(folderName, isDirectory: true)
        let base = (audioFileName as NSString).deletingPathExtension
        let ext = (audioFileName as NSString).pathExtension
        return RecordingFolder(
            folderURL: folderURL,
            baseName: base.isEmpty ? folderName : base,
            audioFileExtension: ext.isEmpty ? "m4a" : ext
        )
    }

    public func audioURL(inRoot root: URL) -> URL {
        root
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(audioFileName)
    }

    /// The verbatim response on disk, if one has been written.
    public func rawResponseURL(inRoot root: URL) -> URL? {
        guard let rawResponseFile, !rawResponseFile.isEmpty else { return nil }
        return root
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(rawResponseFile)
    }

    /// Utterances in transcript order.
    public var orderedUtterances: [Utterance] {
        utterances.sorted { $0.index < $1.index }
    }

    /// Speaker slots in diarized-label order ("A", "B", …).
    public var orderedSpeakerSlots: [SpeakerSlot] {
        speakerSlots.sorted { $0.diarizedSpeaker < $1.diarizedSpeaker }
    }

    /// Names of the people resolved in this recording — the library's
    /// "detected participants" column.
    public var participantNames: [String] {
        orderedSpeakerSlots.compactMap { $0.person?.name ?? $0.matchedName }
    }
}
