import Foundation
import SwiftData

/// The transcript editor's speaker operations, as mutations on the models
/// themselves (spec §Library and editor: "reassign one segment's speaker;
/// reassign *all* segments of a diarized speaker at once; merge two speakers
/// that diarization split").
///
/// These live in `Core` rather than in the app's view model for one reason:
/// they are the only editor logic that is genuinely *about the data model*.
/// Moving an utterance between slots has to keep four things in step —
/// `Utterance.speakerSlot`, `Utterance.diarizedSpeaker`, both slots'
/// `utterances` arrays, and the `unknownIndex` numbering — and getting that
/// wrong produces a transcript that renders one way and exports another. That
/// is a unit test's job, not a UI click-through's.
///
/// Everything here is deliberately *mechanical*. None of it decides whether an
/// assignment is a human confirmation worth learning from, and none of it folds
/// an embedding into a profile — that is the caller's call, through
/// ``SwiftDataProfileSource``, exactly as ``SpeakerSlot/assign(_:confirmed:)``
/// already documents.
extension Recording {

    // MARK: - Lookup

    /// The slot carrying this diarized label, if any.
    public func speakerSlot(labeled diarizedSpeaker: String) -> SpeakerSlot? {
        speakerSlots.first { $0.diarizedSpeaker == diarizedSpeaker }
    }

    /// The slot already resolved to this person in *this* recording.
    ///
    /// Reassigning a single utterance to someone prefers an existing slot over
    /// minting a new one: diarization usually did find that voice, and folding
    /// the utterance back into the real cluster keeps one person from occupying
    /// two slots of the same transcript.
    public func speakerSlot(forPersonID personID: UUID) -> SpeakerSlot? {
        orderedSpeakerSlots.first { $0.person?.id == personID }
    }

    /// The next diarized label not already in use: `A`, `B`, … `Z`, `AA`, `AB`.
    ///
    /// Provider labels are the same alphabet, so a synthetic slot reads like
    /// any other ("Speaker D") in the rare case it is ever shown without a
    /// name. A re-process rebuilds every slot from the raw response and
    /// therefore drops synthetic ones — which is what "re-process" means.
    public func nextDiarizedSpeakerLabel() -> String {
        let taken = Set(speakerSlots.map(\.diarizedSpeaker))
        var ordinal = 0
        while true {
            let candidate = Self.diarizedLabel(ordinal: ordinal)
            if !taken.contains(candidate) { return candidate }
            ordinal += 1
        }
    }

    /// Bijective base-26: 0 → `A`, 25 → `Z`, 26 → `AA`.
    static func diarizedLabel(ordinal: Int) -> String {
        var remaining = max(0, ordinal)
        var label = ""
        repeat {
            let letter = Character(UnicodeScalar(65 + UInt8(remaining % 26)))
            label = String(letter) + label
            remaining = remaining / 26 - 1
        } while remaining >= 0
        return label
    }

    // MARK: - Unknown-speaker numbering

    /// Renumbers unnamed slots `Unknown Speaker 1…N` in diarized-label order,
    /// and clears the placeholder from any slot that now has a person.
    ///
    /// `SpeakerSlot.unknownIndex` documents itself as "non-nil exactly when
    /// `person` is nil"; naming a speaker or merging two of them breaks that on
    /// its own, so every mutation here ends by restoring it. The numbering rule
    /// is deliberately the same one `TranscriptionJob.rebuild` applies (1-based,
    /// in label order), so the labels a user sees after editing are the labels a
    /// re-process would produce — the alternative is a library where "Unknown
    /// Speaker 2" means something different depending on its history.
    ///
    /// - Returns: How many slots are still unnamed.
    @discardableResult
    public func renumberUnknownSpeakers() -> Int {
        var next = 0
        for slot in orderedSpeakerSlots {
            if slot.person == nil {
                next += 1
                slot.unknownIndex = next
            } else {
                slot.unknownIndex = nil
            }
        }
        return next
    }

    // MARK: - Reassigning one utterance

    /// Moves one utterance under `slot`.
    ///
    /// `diarizedSpeaker` moves with it. The field records which slot the row
    /// belongs to (it is what renders when the relationship is nil), and a row
    /// that says "A" while pointing at slot B is a latent display bug. The
    /// provenance is not lost: `transcript.raw.json` still holds what
    /// diarization actually said, which is the thing a re-process reads.
    public func reassign(_ utterance: Utterance, to slot: SpeakerSlot) {
        guard utterance.speakerSlot !== slot else { return }

        utterance.speakerSlot?.utterances.removeAll { $0 === utterance }
        utterance.speakerSlot = slot
        utterance.diarizedSpeaker = slot.diarizedSpeaker
        if !slot.utterances.contains(where: { $0 === utterance }) {
            slot.utterances.append(utterance)
        }
    }

    /// Adds a slot for `person` (or an empty unnamed one) and returns it.
    ///
    /// The slot carries **no cluster embedding**: nothing was measured about
    /// this voice, only asserted about one line of text. `hasClusterEmbedding`
    /// is therefore false, which is exactly what stops the auto-learn path from
    /// folding a fabricated vector into a profile.
    @discardableResult
    public func addSpeakerSlot(for person: Person?, in context: ModelContext) -> SpeakerSlot {
        let slot = SpeakerSlot(
            diarizedSpeaker: nextDiarizedSpeakerLabel(),
            clusterEmbedding: [],
            meetsTarget: false,
            spanCount: 0
        )
        context.insert(slot)
        // Only the to-many side is set, and SwiftData maintains
        // `SpeakerSlot.recording` as its inverse — the same way
        // `TranscriptionJob.rebuild` attaches the slots it mints. Setting both
        // sides by hand is what produces duplicated relationship entries.
        speakerSlots.append(slot)

        if let person { slot.assign(person, confirmed: true) }
        renumberUnknownSpeakers()
        return slot
    }

    // MARK: - Merging two diarized speakers

    /// Merges `source` into `destination`: every utterance of `source` ends up
    /// under `destination`, and `source` is deleted.
    ///
    /// This is the "diarization split one person in two" repair. The surviving
    /// slot keeps its own person and its own cluster embedding — the absorbed
    /// embedding is *returned* rather than averaged in, because the useful
    /// place for it is the person's profile (where auto-learn stores each real
    /// observation separately and the matcher takes the max over them), not a
    /// per-recording average that nothing reads again.
    ///
    /// - Returns: What moved, and the absorbed slot's embedding, so the caller
    ///   can fold it into the resulting person.
    @discardableResult
    public func mergeSpeakerSlot(
        _ source: SpeakerSlot,
        into destination: SpeakerSlot,
        in context: ModelContext
    ) -> SpeakerMergeOutcome {
        guard source !== destination else {
            return SpeakerMergeOutcome(
                absorbedLabel: source.diarizedSpeaker,
                survivingLabel: destination.diarizedSpeaker,
                movedUtteranceCount: 0,
                absorbedClusterEmbedding: [],
                personID: destination.person?.id
            )
        }

        let moving = source.utterances
        for utterance in moving {
            utterance.speakerSlot = destination
            utterance.diarizedSpeaker = destination.diarizedSpeaker
        }

        // Normalize both sides by hand rather than trusting the inverse
        // relationship to have done it: whichever way SwiftData maintained it,
        // this lands on the same state, and the alternative is a duplicated or
        // dropped paragraph in the very operation that is meant to repair one.
        source.utterances = []
        let present = Set(destination.utterances.map(\.index))
        destination.utterances.append(contentsOf: moving.filter { !present.contains($0.index) })

        let absorbed = source.clusterEmbedding
        let absorbedLabel = source.diarizedSpeaker

        speakerSlots.removeAll { $0 === source }
        context.delete(source)

        renumberUnknownSpeakers()

        return SpeakerMergeOutcome(
            absorbedLabel: absorbedLabel,
            survivingLabel: destination.diarizedSpeaker,
            movedUtteranceCount: moving.count,
            absorbedClusterEmbedding: absorbed,
            personID: destination.person?.id
        )
    }
}

// MARK: - Export bridge

extension TranscriptDocument {

    /// Builds the export document from a recording's **current rows**.
    ///
    /// The bridge between the two halves of `Core` that the app otherwise has
    /// to hand-wire: persistence on one side, the renderers on the other. It
    /// lives here rather than in the app layer so that the claim the spec makes
    /// about exports — that they carry the edited text and the assigned speaker
    /// names, never `transcript.raw.json` — is something a test can hold onto.
    ///
    /// Speaker names come from ``Utterance/displaySpeakerName``, the same
    /// resolution the editor renders: a person's name, else "Unknown Speaker N",
    /// else the bare diarized letter. So an export never has a nameless header,
    /// and the document on disk reads exactly like the screen it came from.
    public init(recording: Recording) {
        self.init(
            title: recording.title,
            date: recording.createdAt,
            utterances: recording.orderedUtterances.map {
                TranscriptDocument.Utterance(
                    speaker: $0.displaySpeakerName,
                    startMs: $0.startMs,
                    text: $0.text
                )
            }
        )
    }
}

/// What a speaker merge did — a `Sendable` value, so it can cross back to the
/// caller's actor and drive the auto-learn fold-in.
public struct SpeakerMergeOutcome: Sendable, Equatable {

    /// The diarized label that no longer exists.
    public var absorbedLabel: String

    /// The label everything now lives under.
    public var survivingLabel: String

    /// How many utterances changed slot.
    public var movedUtteranceCount: Int

    /// The absorbed slot's cluster embedding, empty when it had none.
    ///
    /// Worth folding into the surviving person's profile: the user has just
    /// stated that this second voice cluster *is* that person, which is the
    /// same claim naming an unknown speaker makes (spec §4).
    public var absorbedClusterEmbedding: [Float]

    /// The person the merged slot resolves to, if any.
    public var personID: UUID?

    public init(
        absorbedLabel: String,
        survivingLabel: String,
        movedUtteranceCount: Int,
        absorbedClusterEmbedding: [Float],
        personID: UUID?
    ) {
        self.absorbedLabel = absorbedLabel
        self.survivingLabel = survivingLabel
        self.movedUtteranceCount = movedUtteranceCount
        self.absorbedClusterEmbedding = absorbedClusterEmbedding
        self.personID = personID
    }
}
