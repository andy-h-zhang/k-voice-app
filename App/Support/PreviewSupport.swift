#if DEBUG

import Foundation
import KVoiceCore
import SwiftData

/// A disposable app, seeded with fake data, for `#Preview`.
///
/// ## Why this exists
///
/// Every screen reads its state from `AppServices` in the environment, so a
/// preview needs a whole one — and `AppServices` is not a protocol, deliberately
/// (see its own doc comment). The alternative to this file is rebuilding and
/// relaunching the app to look at a button, which is minutes per iteration
/// against a preview's fraction of a second.
///
/// Nothing here is a test double in the mocking sense: the container, the
/// models, and the services are the real ones. Only the *inputs* are fake — a
/// temporary library folder, an in-memory API key, and hand-written utterances
/// standing in for a transcript that would otherwise cost an AssemblyAI call to
/// produce.
///
/// ## What it does not fake
///
/// The audio file is not written, so previews of the editor show the transport
/// bar's "The audio file is missing" notice. That is honest — the fixture has no
/// audio — and it doubles as a free preview of that failure state. Playback is
/// the one thing you cannot iterate on here.
@MainActor
struct PreviewFixture {

    /// The states worth looking at. Each corresponds to a distinct branch of
    /// `TranscriptEditorView` — between them they cover every path through the
    /// `isEmpty` / `failureMessage` / `hasAPIKey` decision tree.
    enum Scenario {
        /// A finished transcript: two named speakers, one unnamed, several turns.
        case populated
        /// No transcript, key configured — the "No Transcript Yet" state with a
        /// live Transcribe button.
        case empty
        /// A failed job, so the empty state shows the error and "Try Again".
        case failed
        /// No transcript and no key — the state a fresh install is in.
        case noAPIKey
    }

    let services: AppServices
    let recordingID: UUID

    static func make(_ scenario: Scenario) -> PreviewFixture {
        // A throwaway library per fixture, so previews never touch the real
        // one in ~/Documents/KVoice — a preview that deleted a recording, or
        // wrote an export, would otherwise do it to actual user data.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KVoicePreviews", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        let settings = SettingsStore.ephemeral(defaultStorageFolderURL: root)
        let keychain = InMemoryAPIKeyStore(apiKey: scenario == .noAPIKey ? nil : "preview-key")

        do {
            let services = try AppServices(settings: settings, keychain: keychain)
            let recordingID = try seed(scenario, into: services.container)
            services.library.reload()
            return PreviewFixture(services: services, recordingID: recordingID)
        } catch {
            // A preview cannot report an error usefully, and a fixture that
            // half-built would fail later in a much more confusing place.
            fatalError("Preview fixture could not be built: \(error)")
        }
    }

    // MARK: - Seeding

    /// A fixed date, not `Date()`, so a preview's subtitle does not change
    /// every time it re-renders.
    private static let createdAt = Date(timeIntervalSince1970: 1_786_579_200)

    private static func seed(_ scenario: Scenario, into container: ModelContainer) throws -> UUID {
        let context = ModelContext(container)

        let status: RecordingStatus =
            switch scenario {
            case .populated: .done
            case .failed: .failed(message: "AssemblyAI rejected the API key (401 Unauthorized).")
            case .empty, .noAPIKey: .recorded
            }

        let recording = Recording(
            title: "2026-08-13 Weekly Sync",
            folderName: "2026-08-13 Weekly Sync",
            audioFileName: "2026-08-13 Weekly Sync Recording.m4a",
            createdAt: createdAt,
            durationSec: 372,
            status: status
        )
        context.insert(recording)

        if scenario == .populated {
            addTranscript(to: recording, in: context)
        }

        try context.save()
        return recording.id
    }

    /// Wires slots and utterances the same way `TranscriptionJob.rebuild` does
    /// — insert, append to the recording, then append to the owning slot. A row
    /// that skips the last step has no speaker and renders blank.
    private static func addTranscript(to recording: Recording, in context: ModelContext) {
        var slots: [String: SpeakerSlot] = [:]

        for (letter, name) in [("A", "Alice Chen"), ("B", "Bob Ortiz")] {
            let person = Person(name: name)
            context.insert(person)

            let slot = SpeakerSlot(diarizedSpeaker: letter, spanCount: 3)
            context.insert(slot)
            recording.speakerSlots.append(slot)
            slot.assign(person, confirmed: true)
            slots[letter] = slot
        }

        // One deliberately unnamed speaker, so the previews show what
        // "Unknown Speaker 1" actually looks like next to real names — that
        // row is the one speaker assignment has to be designed around.
        let unknown = SpeakerSlot(diarizedSpeaker: "C", unknownIndex: 1, spanCount: 1)
        context.insert(unknown)
        recording.speakerSlots.append(unknown)
        slots["C"] = unknown

        let script: [(speaker: String, startMs: Int, endMs: Int, text: String)] = [
            ("A", 5_000, 11_400, "Morning, everyone. Let's keep this one short — I've got three "
                + "things on the list and the last one needs a decision."),
            ("B", 11_800, 19_200, "Morning. Before you start, did the migration finish overnight? "
                + "I saw the job go green but I haven't checked the row counts."),
            ("A", 19_600, 27_100, "It finished. Counts match on both sides, and I spot-checked "
                + "the three tables we were worried about."),
            ("C", 27_500, 31_000, "Can we get the dashboard pointed at the new tables this week?"),
            ("A", 31_400, 40_800, "That's item two, actually. I'd rather do it Thursday so we "
                + "have a full day of clean data behind us before anyone looks at a chart."),
            ("B", 41_200, 48_600, "Thursday works. I'll take the dashboard side if you handle "
                + "the migration cleanup — there are still shadow tables to drop."),
        ]

        for (index, line) in script.enumerated() {
            let utterance = Utterance(
                index: index,
                diarizedSpeaker: line.speaker,
                text: line.text,
                startMs: line.startMs,
                endMs: line.endMs
            )
            context.insert(utterance)
            recording.utterances.append(utterance)
            slots[line.speaker]?.utterances.append(utterance)
        }
    }
}

#endif
