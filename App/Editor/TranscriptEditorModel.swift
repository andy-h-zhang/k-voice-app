import Foundation
import KVoiceCore
import Observation
import SwiftData

// MARK: - Value types the views render

/// One utterance, as the editor holds it.
///
/// A value copy rather than the `Utterance` row: views must never hold a
/// `PersistentModel` whose context has moved on, and every mutation here opens
/// its own context anyway. `index` is the address — it is unique within a
/// recording, stable across edits (nothing renumbers utterances), and cheaper
/// to pass around than a `PersistentIdentifier`.
struct EditorUtterance: Identifiable, Equatable {
    let index: Int
    var text: String
    var startMs: Int
    var endMs: Int
    /// Diarized label of the slot this row belongs to.
    var speakerLabel: String
    /// Resolved display name — a person, or "Unknown Speaker N".
    var speakerName: String
    var isEdited: Bool

    var id: Int { index }
}

/// A run of consecutive utterances by one speaker — what the screen renders as
/// a header plus paragraphs.
///
/// Produced by ``TranscriptDocument/turns(from:)``, the same grouping the three
/// exporters use, so the editor and the exported document can never disagree
/// about where a turn starts. This type carries only the *indices* of its
/// paragraphs: the text lives in one place (``TranscriptEditorModel``) and a
/// keystroke therefore does not have to rebuild the turn structure.
struct EditorTurn: Identifiable, Equatable {
    /// Index of the turn's first utterance — stable, and unique per turn.
    let id: Int
    var speakerLabel: String
    var speakerName: String
    var startMs: Int
    var utteranceIndices: [Int]
}

/// One diarized speaker of this recording (one `SpeakerSlot`).
struct EditorSpeaker: Identifiable, Equatable {
    /// The diarized label, "A"…, which is also the address of the slot.
    let label: String
    var displayName: String
    var personID: UUID?
    var isUnknown: Bool
    var isConfirmed: Bool
    var utteranceCount: Int
    var hasClusterEmbedding: Bool
    /// Best profile name at match time, even when it fell below the threshold —
    /// the near-miss worth showing while naming.
    var matchedName: String?
    var matchScore: Float?

    var id: String { label }

    /// "Bob (0.58)" — the hint under a naming prompt, or nil when matching
    /// never produced a candidate.
    var nearMissDescription: String? {
        guard isUnknown, let matchedName, let matchScore else { return nil }
        return String(format: "Closest profile: %@ (%.2f)", matchedName, matchScore)
    }
}

/// A person the user picked, or typed.
enum PersonChoice: Equatable {
    case existing(id: UUID, name: String)
    case new(name: String)

    var displayName: String {
        switch self {
        case .existing(_, let name), .new(let name): return name
        }
    }
}

/// A profile in the picker.
struct PersonOption: Identifiable, Equatable {
    let id: UUID
    let name: String
    let embeddingCount: Int
}

// MARK: - Model

/// The transcript editor's state and every mutation it offers (plan §2 Phase 5).
///
/// ## Where the truth lives
///
/// SwiftData is the truth; this holds a value-typed copy for rendering. Every
/// mutation opens a fresh `ModelContext`, writes, saves, and reloads — the same
/// pattern `LibraryModel` uses, and for the same reason: a transcription job
/// running in the background writes through a *different* context, so a
/// long-lived one here would serve stale rows.
///
/// ## Why text edits do not go through the observed state
///
/// `turns` and `speakers` are `@Observable`; the per-utterance text is
/// deliberately **not**. A 60-minute meeting is ~700 paragraphs, and publishing
/// every keystroke would invalidate all of them. Instead a paragraph view owns
/// its own draft, edits land in ``pendingEdits`` (observation-ignored), and a
/// debounce writes them to the `Utterance` rows. Structure only changes on
/// ``reload()``, which speaker operations call — so typing costs zero view
/// invalidation and the database still ends up holding every edit.
@MainActor
@Observable
final class TranscriptEditorModel {

    // MARK: Identity

    let recordingID: UUID

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let profiles: SwiftDataProfileSource
    @ObservationIgnored private let libraryRoot: URL

    // MARK: Observed state

    private(set) var title: String = ""
    private(set) var createdAt: Date = .distantPast
    private(set) var durationSec: Double = 0

    /// Speaker turns, in transcript order.
    private(set) var turns: [EditorTurn] = []

    /// The recording's diarized speakers, in label order.
    private(set) var speakers: [EditorSpeaker] = []

    /// Every enrolled profile, for the assignment pickers.
    private(set) var people: [PersonOption] = []

    /// True once a load has run and found no utterances — the "nothing to edit
    /// yet" state, e.g. a recording that has not been transcribed.
    private(set) var isEmpty = false

    /// Shown as an alert.
    var errorMessage: String?

    /// A transient confirmation ("Learned Bob's voice — 4 samples stored").
    var statusMessage: String?

    // MARK: Unobserved state

    /// Per-utterance data, addressed by index. Not observed: see the type
    /// comment. Rebuilt wholesale by ``reload()``.
    @ObservationIgnored private var utterancesByIndex: [Int: EditorUtterance] = [:]

    /// Edits waiting to be written to their rows.
    @ObservationIgnored private var pendingEdits: [Int: String] = [:]
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var statusDismissal: Task<Void, Never>?

    /// How long a paragraph must sit unchanged before its text is persisted.
    static let editDebounce = Duration.milliseconds(600)

    // MARK: - Init

    init(
        recordingID: UUID,
        container: ModelContainer,
        profiles: SwiftDataProfileSource,
        libraryRoot: URL
    ) {
        self.recordingID = recordingID
        self.container = container
        self.profiles = profiles
        self.libraryRoot = libraryRoot
    }

    // MARK: - Files

    var folderURL: URL {
        libraryRoot.appendingPathComponent(folderName, isDirectory: true)
    }

    var audioURL: URL {
        folderURL.appendingPathComponent(audioFileName)
    }

    @ObservationIgnored private var folderName: String = ""
    @ObservationIgnored private var audioFileName: String = ""

    // MARK: - Reading

    /// Re-reads everything from the database.
    func reload() {
        do {
            let context = ModelContext(container)
            guard let recording = try context.recording(id: recordingID) else {
                errorMessage = "This recording is no longer in the library."
                return
            }

            title = recording.title
            createdAt = recording.createdAt
            durationSec = recording.durationSec
            folderName = recording.folderName
            audioFileName = recording.audioFileName

            let rows = recording.orderedUtterances.map { row in
                EditorUtterance(
                    index: row.index,
                    text: row.text,
                    startMs: row.startMs,
                    endMs: row.endMs,
                    speakerLabel: row.diarizedSpeaker,
                    speakerName: row.displaySpeakerName,
                    isEdited: row.isEdited
                )
            }
            utterancesByIndex = Dictionary(uniqueKeysWithValues: rows.map { ($0.index, $0) })
            turns = Self.turns(from: rows)
            speakers = recording.orderedSpeakerSlots.map { slot in
                EditorSpeaker(
                    label: slot.diarizedSpeaker,
                    displayName: slot.displayName,
                    personID: slot.person?.id,
                    isUnknown: slot.isUnknown,
                    isConfirmed: slot.isConfirmed,
                    utteranceCount: slot.utterances.count,
                    hasClusterEmbedding: slot.hasClusterEmbedding,
                    matchedName: slot.matchedName,
                    matchScore: slot.matchScore
                )
            }
            isEmpty = rows.isEmpty
        } catch {
            errorMessage = "Could not read this transcript: \(LibraryModel.describe(error))"
        }
    }

    /// Re-reads the profile library, for the assignment pickers.
    func refreshPeople() async {
        do {
            let library = try await profiles.library()
            people = library.profiles
                .map { PersonOption(id: $0.id, name: $0.name, embeddingCount: $0.embeddingCount) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            errorMessage = "Could not read the voice profiles: \(LibraryModel.describe(error))"
        }
    }

    /// The utterance at this index, or nil.
    func utterance(_ index: Int) -> EditorUtterance? {
        utterancesByIndex[index]
    }

    /// The text a paragraph field should start from: the pending draft if one
    /// is in flight, otherwise what is stored.
    func text(forUtterance index: Int) -> String {
        pendingEdits[index] ?? utterancesByIndex[index]?.text ?? ""
    }

    /// The speaker of a given diarized label.
    func speaker(labeled label: String) -> EditorSpeaker? {
        speakers.first { $0.label == label }
    }

    /// Every utterance in transcript order — the playback highlight's spans.
    var orderedUtterances: [EditorUtterance] {
        utterancesByIndex.values.sorted { $0.index < $1.index }
    }

    // MARK: - Grouping

    /// Groups utterances into turns using Core's grouping, then maps each
    /// paragraph back to the row that produced it.
    ///
    /// The mapping rests on the invariant `TranscriptDocument.turns(from:)`
    /// documents: blank utterances are dropped, and every surviving utterance
    /// becomes exactly one paragraph, in input order. So walking the surviving
    /// rows in parallel with the paragraphs pairs them off exactly — which is
    /// why the editor can reuse the exporters' grouping instead of growing a
    /// second one that would eventually drift from it.
    static func turns(from utterances: [EditorUtterance]) -> [EditorTurn] {
        let grouped = TranscriptDocument.turns(
            from: utterances.map {
                TranscriptDocument.Utterance(
                    speaker: $0.speakerName,
                    startMs: $0.startMs,
                    text: $0.text
                )
            }
        )

        let surviving = utterances.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        var cursor = 0
        var result: [EditorTurn] = []
        result.reserveCapacity(grouped.count)

        for turn in grouped {
            let start = cursor
            var indices: [Int] = []
            indices.reserveCapacity(turn.paragraphs.count)
            for _ in turn.paragraphs {
                guard cursor < surviving.count else { break }
                indices.append(surviving[cursor].index)
                cursor += 1
            }
            guard let first = indices.first else { continue }
            result.append(
                EditorTurn(
                    id: first,
                    // Two slots can share a display name (both assigned to the
                    // same person), and Core groups by name — so the turn's
                    // *slot* is the one its first paragraph came from.
                    speakerLabel: surviving[start].speakerLabel,
                    speakerName: turn.speaker,
                    startMs: turn.startMs,
                    utteranceIndices: indices
                )
            )
        }
        return result
    }

    // MARK: - Editing text

    /// Records a keystroke. The write is debounced; nothing is published.
    func setText(_ text: String, forUtterance index: Int) {
        guard utterancesByIndex[index] != nil else { return }
        pendingEdits[index] = text

        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: Self.editDebounce)
            guard !Task.isCancelled else { return }
            self?.flushPendingEdits()
        }
    }

    /// Writes every pending edit to its `Utterance` row, in one save.
    ///
    /// Called before any speaker operation and before any export, so those
    /// always see the text the user has actually typed, and on the way out of
    /// the screen. Edits land on the row and never on `transcript.raw.json`
    /// (spec §Library and editor: "edits persist to the database, not the raw
    /// API response").
    func flushPendingEdits() {
        debounce?.cancel()
        debounce = nil

        guard !pendingEdits.isEmpty else { return }
        let edits = pendingEdits
        pendingEdits = [:]

        do {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            guard let recording = try context.recording(id: recordingID) else { return }

            var rows: [Int: Utterance] = [:]
            for row in recording.utterances { rows[row.index] = row }

            for (index, text) in edits {
                guard let row = rows[index], row.text != text else { continue }
                // A paragraph cleared to nothing is not persisted: Core's
                // grouping drops blank utterances, so the row would vanish from
                // the screen mid-edit and could not be typed back into. The
                // field restores the stored text instead.
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

                row.text = text
                row.isEdited = true
                utterancesByIndex[index]?.text = text
                utterancesByIndex[index]?.isEdited = true
            }

            if context.hasChanges { try context.save() }
        } catch {
            errorMessage = "Could not save your edit: \(LibraryModel.describe(error))"
        }
    }

    // MARK: - Speaker operations

    /// Assigns a person to a whole diarized speaker — naming an unknown one, or
    /// correcting a wrong match. **Triggers auto-learn** (spec §4).
    ///
    /// This is the one the acceptance criterion turns on: the slot's cluster
    /// embedding was persisted at matching time precisely so that naming the
    /// speaker later folds a real voice vector into the profile without
    /// re-reading the audio, and the *next* recording recognizes them.
    func assignSpeaker(labeled label: String, to choice: PersonChoice) async {
        flushPendingEdits()
        do {
            let personID = try await resolve(choice)

            let embedding: [Float] = try withRecording { recording, context in
                guard let slot = recording.speakerSlot(labeled: label),
                    let person = try context.person(id: personID)
                else { return [] }

                slot.assign(person, confirmed: true)
                recording.renumberUnknownSpeakers()
                return slot.clusterEmbedding
            }

            try await learn(embedding, personID: personID, verb: "Named")
            reload()
        } catch {
            errorMessage = "Could not assign that speaker: \(LibraryModel.describe(error))"
        }
    }

    /// Detaches a person from a speaker, restoring "Unknown Speaker N".
    ///
    /// No un-learning: the embedding already folded into that profile stays.
    /// Auto-learn is a running average of observations, and the escape hatch
    /// for a profile that has learned the wrong voice is "reset learned voice"
    /// in People, not a per-recording undo.
    func clearSpeaker(labeled label: String) {
        flushPendingEdits()
        do {
            try withRecording { recording, _ in
                guard let slot = recording.speakerSlot(labeled: label) else { return }
                slot.clearPerson(unknownIndex: nil)
                recording.renumberUnknownSpeakers()
            }
            reload()
        } catch {
            errorMessage = "Could not clear that speaker: \(LibraryModel.describe(error))"
        }
    }

    /// Moves one utterance under an existing speaker of this recording.
    ///
    /// **No auto-learn**, deliberately. Embeddings exist per *speaker slot*, not
    /// per utterance (plan §1), so the only vector this could fold in is the
    /// whole cluster's — and one reassigned line is not evidence that an entire
    /// voice cluster belongs to someone else. Folding it would teach the
    /// profile the wrong voice, which is the failure mode auto-learn exists to
    /// avoid. Whole-speaker reassignment is the operation that carries that
    /// claim, and it does learn.
    func reassignUtterance(_ index: Int, toSpeakerLabeled label: String) {
        flushPendingEdits()
        do {
            try withRecording { recording, _ in
                guard let slot = recording.speakerSlot(labeled: label),
                    let utterance = recording.utterances.first(where: { $0.index == index })
                else { return }
                recording.reassign(utterance, to: slot)
            }
            reload()
        } catch {
            errorMessage = "Could not reassign that line: \(LibraryModel.describe(error))"
        }
    }

    /// Moves one utterance to a person, reusing that person's slot in this
    /// recording or minting one. **No auto-learn** — see
    /// ``reassignUtterance(_:toSpeakerLabeled:)``.
    func reassignUtterance(_ index: Int, to choice: PersonChoice) async {
        flushPendingEdits()
        do {
            let personID = try await resolve(choice)

            try withRecording { recording, context in
                guard let person = try context.person(id: personID),
                    let utterance = recording.utterances.first(where: { $0.index == index })
                else { return }

                let slot = recording.speakerSlot(forPersonID: personID)
                    ?? recording.addSpeakerSlot(for: person, in: context)
                recording.reassign(utterance, to: slot)
                recording.renumberUnknownSpeakers()
            }
            reload()
        } catch {
            errorMessage = "Could not reassign that line: \(LibraryModel.describe(error))"
        }
    }

    /// Merges two diarized speakers that were the same person all along.
    ///
    /// **Triggers auto-learn** when the survivor is a named person: the user has
    /// just stated that a second voice cluster is also them, which is the same
    /// claim naming an unknown speaker makes, and the absorbed cluster
    /// embedding is a genuine second observation of that voice.
    func mergeSpeaker(labeled sourceLabel: String, into destinationLabel: String) async {
        flushPendingEdits()
        guard sourceLabel != destinationLabel else { return }

        do {
            let outcome: SpeakerMergeOutcome? = try withRecording { recording, context in
                guard let source = recording.speakerSlot(labeled: sourceLabel),
                    let destination = recording.speakerSlot(labeled: destinationLabel)
                else { return nil }

                // The merge is itself a human confirmation of the survivor's
                // identity, so a match that was only auto-assigned becomes
                // confirmed and a later re-process will not overrule it.
                if destination.person != nil { destination.isConfirmed = true }
                return recording.mergeSpeakerSlot(source, into: destination, in: context)
            }

            if let outcome, let personID = outcome.personID {
                try await learn(outcome.absorbedClusterEmbedding, personID: personID, verb: "Merged into")
            }
            reload()
        } catch {
            errorMessage = "Could not merge those speakers: \(LibraryModel.describe(error))"
        }
    }

    // MARK: - Implementation

    /// Resolves a picked-or-typed person to a row id, creating the profile if
    /// the name is new.
    ///
    /// Creation goes through `SwiftDataProfileSource` rather than a raw insert
    /// so that a typed name matches an existing profile by the *same*
    /// case-insensitive rule the matcher uses — typing "bob" must not mint a
    /// second Bob.
    private func resolve(_ choice: PersonChoice) async throws -> UUID {
        switch choice {
        case .existing(let id, _):
            return id
        case .new(let name):
            return try await profiles.upsertPerson(named: name)
        }
    }

    /// The auto-learn fold-in (spec §4), with the message it reports.
    private func learn(_ embedding: [Float], personID: UUID, verb: String) async throws {
        guard !embedding.isEmpty else {
            // A slot with no cluster embedding — the speaker was never
            // measured (no clean span, or a synthetic slot). The assignment
            // still stands; there is simply nothing to learn from.
            return
        }
        let outcome = try await profiles.foldIn(
            embedding,
            intoPersonWithID: personID,
            source: .autolearn
        )
        guard outcome.stored else { return }
        show(
            "\(verb) \(outcome.name) — learned this voice "
                + "(\(outcome.embeddingCount) sample\(outcome.embeddingCount == 1 ? "" : "s") stored)."
        )
    }

    /// Shows a status line and clears it a few seconds later.
    private func show(_ message: String) {
        statusMessage = message
        statusDismissal?.cancel()
        statusDismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.statusMessage = nil
        }
    }

    /// Runs `body` against this recording in a fresh context, saving once.
    ///
    /// `body` must not return a `PersistentModel` — the same rule
    /// `SwiftDataProfileSource` and `TranscriptionJob` hold themselves to.
    @discardableResult
    private func withRecording<T>(_ body: (Recording, ModelContext) throws -> T) throws -> T {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard let recording = try context.recording(id: recordingID) else {
            throw TranscriptEditorError.recordingNotFound
        }
        let result = try body(recording, context)
        if context.hasChanges { try context.save() }
        return result
    }
}

/// Failures the editor raises on its own behalf.
enum TranscriptEditorError: LocalizedError {
    case recordingNotFound

    var errorDescription: String? {
        switch self {
        case .recordingNotFound:
            return "This recording is no longer in the library."
        }
    }
}
