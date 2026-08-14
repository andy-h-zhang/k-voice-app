import AVFoundation
import Foundation
import SwiftData
import Testing

@testable import KVoiceCore

// MARK: - Shared helpers

extension TranscriptionJob {
    /// A job wired for tests: instant polling, a fixed clock, no network
    /// unless the provider was scripted to allow it.
    static func forTest(
        fixture: RecordingFixture,
        provider: any TranscriptionProvider,
        matching: any SpeakerMatching,
        profiles: any ProfileSource = StaticProfileSource(ProfileLibrary()),
        settings: SettingsSnapshot? = nil,
        maxConsecutiveFailures: Int = 3
    ) -> TranscriptionJob {
        TranscriptionJob(
            recordingID: fixture.id,
            container: fixture.container,
            provider: provider,
            matching: matching,
            profiles: profiles,
            settings: settings ?? fixture.settings,
            configuration: .init(poller: .instant(maxConsecutiveFailures: maxConsecutiveFailures)),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }
}

private func makePerson(_ container: ModelContainer, name: String) throws -> UUID {
    let context = ModelContext(container)
    let person = Person(name: name)
    context.insert(person)
    try context.save()
    return person.id
}

/// The state path a run took, with consecutive duplicates collapsed.
private func statusPath(_ events: [TranscriptionJobEvent]) -> [RecordingStatus.Kind] {
    var path: [RecordingStatus.Kind] = []
    for event in events where path.last != event.status.kind {
        path.append(event.status.kind)
    }
    return path
}

private struct MatchingBlewUp: Error, LocalizedError {
    var errorDescription: String? { "the embedder fell over" }
}

// MARK: - Happy path

@Suite("Transcription job: happy path")
struct TranscriptionJobHappyPathTests {

    @Test("a recording walks recorded → uploading → queued → transcribing → matching → done")
    func endToEnd() async throws {
        let container = try TestContainer.inMemory()
        let fixture = try RecordingFixture(container: container)
        defer { fixture.cleanUp() }

        let aliceID = try makePerson(container, name: "Alice")
        let provider = ScriptedProvider(pollSteps: [
            .response(TranscriptFixtures.inProgress(status: .queued)),
            .response(TranscriptFixtures.inProgress(status: .processing)),
            .response(TranscriptFixtures.completed())
        ])
        let job = TranscriptionJob.forTest(
            fixture: fixture,
            provider: provider,
            matching: matching(["A": ("Alice", aliceID, 0.91), "B": nil])
        )

        let events = await collectEvents(job)
        let status = await job.run()
        let collected = await events.value

        #expect(status == .done)
        #expect(statusPath(collected) == [.recorded, .uploading, .queued, .transcribing, .matching, .done])
        // The stream ends of its own accord at a terminal state.
        #expect(collected.last?.status == .done)

        let snapshot = try fixture.snapshot()
        #expect(snapshot.status == .done)
        #expect(snapshot.assemblyTranscriptId == "t-1")
        #expect(snapshot.uploadedAudioURLString == "https://cdn.assemblyai.com/upload/fixture")
        #expect(snapshot.rawResponseFile == RawTranscriptStore.defaultFileName)
        #expect(snapshot.completedAt != nil)
        // audio_duration from the response fills in a duration we didn't have.
        #expect(snapshot.durationSec == 120)
        #expect(snapshot.utteranceCount == 3)
        #expect(snapshot.speakerSlotCount == 2)
        #expect(snapshot.participantNames == ["Alice"])
    }

    @Test("utterances persist in order, with their text and timings")
    func utterancesPersisted() async throws {
        let container = try TestContainer.inMemory()
        let fixture = try RecordingFixture(container: container)
        defer { fixture.cleanUp() }

        let provider = ScriptedProvider(pollSteps: [.response(TranscriptFixtures.completed())])
        let job = TranscriptionJob.forTest(
            fixture: fixture, provider: provider, matching: matching(["A": nil, "B": nil])
        )
        #expect(await job.run() == .done)

        try fixture.withRecording { recording in
            let utterances = recording.orderedUtterances
            #expect(utterances.map(\.index) == [0, 1, 2])
            #expect(utterances.map(\.diarizedSpeaker) == ["A", "B", "A"])
            #expect(utterances.map(\.startMs) == [0, 6_500, 12_500])
            #expect(utterances.map(\.endMs) == [6_000, 12_000, 18_000])
            #expect(utterances.allSatisfy { !$0.text.isEmpty })
            #expect(utterances.map(\.isEdited) == [false, false, false])
            // Each turn is wired to its speaker's slot.
            #expect(utterances.map { $0.speakerSlot?.diarizedSpeaker } == ["A", "B", "A"])
        }
        #expect(try ModelContext(container).fetch(FetchDescriptor<Utterance>()).count == 3)
    }

    @Test("a matched speaker links to the person; an unmatched one becomes Unknown Speaker 1")
    func slotsResolved() async throws {
        let container = try TestContainer.inMemory()
        let fixture = try RecordingFixture(container: container)
        defer { fixture.cleanUp() }

        let aliceID = try makePerson(container, name: "Alice")
        let provider = ScriptedProvider(pollSteps: [.response(TranscriptFixtures.completed())])
        let job = TranscriptionJob.forTest(
            fixture: fixture,
            provider: provider,
            matching: matching(["A": ("Alice", aliceID, 0.91), "B": nil])
        )
        #expect(await job.run() == .done)

        try fixture.withRecording { recording in
            let slots = recording.orderedSpeakerSlots
            #expect(slots.map(\.diarizedSpeaker) == ["A", "B"])

            let a = slots[0]
            #expect(a.person?.name == "Alice")
            #expect(a.matchedName == "Alice")
            #expect(a.matchScore == 0.91)
            #expect(a.matchThreshold == ClusterMatcher.defaultThreshold)
            #expect(a.unknownIndex == nil)
            // Auto-assigned, not human-confirmed: auto-learn waits for a person.
            #expect(!a.isConfirmed)
            #expect(a.displayName == "Alice")

            let b = slots[1]
            #expect(b.person == nil)
            #expect(b.unknownIndex == 1)
            #expect(b.displayName == "Unknown Speaker 1")
            // The unmatched speaker keeps its voice vector — plan §1's whole
            // point, and what lets naming them later feed auto-learn.
            #expect(b.hasClusterEmbedding)
            #expect(b.clusterEmbedding.count == 256)
        }
    }

    @Test("unknown speakers are numbered from 1 in label order")
    func unknownNumbering() async throws {
        let container = try TestContainer.inMemory()
        let fixture = try RecordingFixture(container: container)
        defer { fixture.cleanUp() }

        var response = TranscriptFixtures.completed()
        response.utterances?.append(Fixture.utterance(speaker: "C", start: 18_500, end: 24_000))
        response.words = response.utterances?.flatMap(\.words)

        let bobID = try makePerson(container, name: "Bob")
        let provider = ScriptedProvider(pollSteps: [.response(response)])
        let job = TranscriptionJob.forTest(
            fixture: fixture,
            provider: provider,
            matching: matching(["A": nil, "B": ("Bob", bobID, 0.8), "C": nil])
        )
        #expect(await job.run() == .done)

        try fixture.withRecording { recording in
            let slots = recording.orderedSpeakerSlots
            #expect(slots.map(\.diarizedSpeaker) == ["A", "B", "C"])
            #expect(slots.map(\.unknownIndex) == [1, nil, 2])
            #expect(slots.map(\.displayName) == ["Unknown Speaker 1", "Bob", "Unknown Speaker 2"])
        }
    }

    @Test("a match with no Person row stays unknown but keeps the near-miss name")
    func matchWithoutPersonRow() async throws {
        // What happens when profiles came from the CLI's JSON library: the
        // matcher is confident, but there is no row to attribute the slot to.
        let container = try TestContainer.inMemory()
        let fixture = try RecordingFixture(container: container)
        defer { fixture.cleanUp() }

        let provider = ScriptedProvider(pollSteps: [.response(TranscriptFixtures.completed())])
        let job = TranscriptionJob.forTest(
            fixture: fixture,
            provider: provider,
            matching: matching(["A": ("Ghost", UUID(), 0.95), "B": nil])
        )
        #expect(await job.run() == .done)

        try fixture.withRecording { recording in
            let a = recording.orderedSpeakerSlots[0]
            #expect(a.person == nil)
            #expect(a.unknownIndex == 1)
            #expect(a.matchedName == "Ghost")
            #expect(a.matchScore == 0.95)
        }
    }

    @Test("a person is resolved by name when the profile id is not a row id")
    func personResolvedByName() async throws {
        let container = try TestContainer.inMemory()
        let fixture = try RecordingFixture(container: container)
        defer { fixture.cleanUp() }

        _ = try makePerson(container, name: "Alice")
        let provider = ScriptedProvider(pollSteps: [.response(TranscriptFixtures.completed())])
        let job = TranscriptionJob.forTest(
            fixture: fixture,
            provider: provider,
            // A profile id from a JSON library, which is nobody's row id.
            matching: matching(["A": ("alice", UUID(), 0.9), "B": nil])
        )
        #expect(await job.run() == .done)

        try fixture.withRecording { recording in
            #expect(recording.orderedSpeakerSlots[0].person?.name == "Alice")
        }
    }

    @Test("keyterms come from settings at submit time and are sanitized")
    func keytermsAtSubmitTime() async throws {
        let container = try TestContainer.inMemory()
        let fixture = try RecordingFixture(container: container)
        defer { fixture.cleanUp() }

        var settings = fixture.settings
        settings.keyterms = [
            "Kizaki",
            "  KVoice  ",
            "this phrase has far too many words to be a valid keyterm",
            "Kizaki"
        ]

        let provider = ScriptedProvider(pollSteps: [.response(TranscriptFixtures.completed())])
        let job = TranscriptionJob.forTest(
            fixture: fixture,
            provider: provider,
            matching: matching(["A": nil, "B": nil]),
            settings: settings
        )
        #expect(await job.run() == .done)

        let request = try #require(provider.lastRequest)
        // Trimmed, de-duplicated, and the over-long phrase dropped.
        #expect(request.keytermsPrompt == ["Kizaki", "KVoice"])
        #expect(request.speakerLabels)
        #expect(request.speechModels == AssemblyAIConstants.defaultSpeechModels)
        #expect(request.audioURL == "https://cdn.assemblyai.com/upload/fixture")
    }

    @Test("an empty keyterms list omits the field entirely")
    func noKeyterms() async throws {
        let container = try TestContainer.inMemory()
        let fixture = try RecordingFixture(container: container)
        defer { fixture.cleanUp() }

        let provider = ScriptedProvider(pollSteps: [.response(TranscriptFixtures.completed())])
        let job = TranscriptionJob.forTest(
            fixture: fixture, provider: provider, matching: matching(["A": nil, "B": nil])
        )
        #expect(await job.run() == .done)
        #expect(provider.lastRequest?.keytermsPrompt == nil)
    }

    @Test("the verbatim response body is saved before it is decoded")
    func rawBodyIsVerbatim() async throws {
        let container = try TestContainer.inMemory()
        let fixture = try RecordingFixture(container: container)
        defer { fixture.cleanUp() }

        // Includes a field our DTO knows nothing about. If we persisted a
        // re-encoding instead of the bytes, it would be gone.
        let raw = Data(
            """
            {"id":"t-1","status":"completed","audio_duration":90,\
            "utterances":[{"speaker":"A","text":"hello","start":0,"end":1000,"words":[]}],\
            "a_field_from_the_future":{"nested":true}}
            """.utf8
        )

        let provider = ScriptedProvider(pollSteps: [.raw(raw)])
        let job = TranscriptionJob.forTest(
            fixture: fixture, provider: provider, matching: matching(["A": nil])
        )
        #expect(await job.run() == .done)

        let onDisk = try Data(contentsOf: fixture.rawTranscriptURL)
        #expect(onDisk == raw)
        #expect(String(decoding: onDisk, as: UTF8.self).contains("a_field_from_the_future"))
    }

    @Test("model and language reported by the provider are recorded")
    func metadataPersisted() async throws {
        let container = try TestContainer.inMemory()
        let fixture = try RecordingFixture(container: container)
        defer { fixture.cleanUp() }

        let provider = ScriptedProvider(pollSteps: [.response(TranscriptFixtures.completed())])
        let job = TranscriptionJob.forTest(
            fixture: fixture, provider: provider, matching: matching(["A": nil, "B": nil])
        )
        #expect(await job.run() == .done)

        try fixture.withRecording { recording in
            #expect(recording.speechModelUsed == "universal-3-5-pro")
            #expect(recording.languageCode == "en_us")
        }
    }

    @Test("running an already-done recording is a no-op")
    func alreadyDoneIsNoOp() async throws {
        let container = try TestContainer.inMemory()
        let fixture = try RecordingFixture(container: container)
        defer { fixture.cleanUp() }

        let provider = ScriptedProvider(pollSteps: [.response(TranscriptFixtures.completed())])
        let job = TranscriptionJob.forTest(
            fixture: fixture, provider: provider, matching: matching(["A": nil, "B": nil])
        )
        #expect(await job.run() == .done)
        let after = provider.counts

        #expect(try await job.resumePlan() == .alreadyDone)
        #expect(await job.run() == .done)
        #expect(provider.counts == after)
    }

    @Test("a late subscriber is told the current state immediately")
    func lateSubscriberGetsReplay() async throws {
        let container = try TestContainer.inMemory()
        let fixture = try RecordingFixture(container: container)
        defer { fixture.cleanUp() }

        let provider = ScriptedProvider(pollSteps: [.response(TranscriptFixtures.completed())])
        let job = TranscriptionJob.forTest(
            fixture: fixture, provider: provider, matching: matching(["A": nil, "B": nil])
        )
        #expect(await job.run() == .done)

        var replayed: [TranscriptionJobEvent] = []
        for await event in await job.events() { replayed.append(event) }
        #expect(replayed.map(\.status) == [.done])
    }
}

// MARK: - Failures and retry

@Suite("Transcription job: failure and retry at every stage")
struct TranscriptionJobFailureTests {

    @Test("a failed upload is retryable and never re-records")
    func uploadFailure() async throws {
        let container = try TestContainer.inMemory()
        let fixture = try RecordingFixture(container: container)
        defer { fixture.cleanUp() }

        let provider = ScriptedProvider(
            uploadResult: .failure(.invalidRequest(status: 400, message: "file rejected"))
        )
        let job = TranscriptionJob.forTest(
            fixture: fixture, provider: provider, matching: matching(["A": nil, "B": nil])
        )

        let status = await job.run()
        #expect(status.kind == .failed)
        #expect(status.failureMessage?.contains("file rejected") == true)

        let failed = try fixture.snapshot()
        #expect(failed.assemblyTranscriptId == nil)
        #expect(failed.uploadedAudioURLString == nil)
        // Nothing to resume from, so the plan is to start over — from the
        // audio file that is still sitting on disk.
        #expect(try await job.resumePlan() == .upload)
        #expect(FileManager.default.fileExists(atPath: fixture.audioURL.path))

        provider.uploadResult = .success(URL(string: "https://cdn.assemblyai.com/upload/fixture")!)
        provider.setPollSteps([.response(TranscriptFixtures.completed())])
        #expect(await job.retry() == .done)
        #expect(provider.counts.upload == 2)
    }

    @Test("a missing audio file fails before any upload is attempted")
    func missingAudio() async throws {
        let container = try TestContainer.inMemory()
        let fixture = try RecordingFixture(container: container, writeAudioFile: false)
        defer { fixture.cleanUp() }

        let provider = ScriptedProvider()
        let job = TranscriptionJob.forTest(
            fixture: fixture, provider: provider, matching: matching([:])
        )

        let status = await job.run()
        #expect(status.kind == .failed)
        #expect(status.failureMessage?.contains("audio file is missing") == true)
        #expect(provider.counts.upload == 0)
    }

    @Test("a failed submit retries without re-uploading the file")
    func submitFailure() async throws {
        let container = try TestContainer.inMemory()
        let fixture = try RecordingFixture(container: container)
        defer { fixture.cleanUp() }

        let provider = ScriptedProvider(
            createResult: .failure(.invalidRequest(status: 400, message: "bad request"))
        )
        let job = TranscriptionJob.forTest(
            fixture: fixture, provider: provider, matching: matching(["A": nil, "B": nil])
        )

        #expect(await job.run() == .failed(message: TranscriptionJob.describe(
            TranscriptionError.invalidRequest(status: 400, message: "bad request")
        )))

        let failed = try fixture.snapshot()
        let uploadURL = try #require(failed.uploadedAudioURLString)
        #expect(failed.assemblyTranscriptId == nil)
        #expect(try await job.resumePlan() == .submit(uploadURL: uploadURL))

        provider.createResult = .success("t-2")
        provider.setPollSteps([.response(TranscriptFixtures.completed(id: "t-2"))])
        #expect(await job.retry() == .done)

        // The whole point: one upload, two submits.
        #expect(provider.counts.upload == 1)
        #expect(provider.counts.create == 2)
        #expect(try fixture.snapshot().assemblyTranscriptId == "t-2")
    }

    @Test("polling that keeps failing keeps the transcript id to resume from")
    func pollFailureKeepsTranscriptID() async throws {
        let container = try TestContainer.inMemory()
        let fixture = try RecordingFixture(container: container)
        defer { fixture.cleanUp() }

        let provider = ScriptedProvider(pollSteps: [
            .failure(.transport(description: "offline")),
            .failure(.transport(description: "offline")),
            .failure(.transport(description: "offline"))
        ])
        let job = TranscriptionJob.forTest(
            fixture: fixture, provider: provider, matching: matching(["A": nil, "B": nil])
        )

        #expect(await job.run().kind == .failed)

        let failed = try fixture.snapshot()
        // A network blip must not cost a re-upload.
        #expect(failed.assemblyTranscriptId == "t-1")
        #expect(try await job.resumePlan() == .poll(transcriptID: "t-1"))

        provider.setPollSteps([.response(TranscriptFixtures.completed())])
        #expect(await job.retry() == .done)
        #expect(provider.counts.upload == 1)
        #expect(provider.counts.create == 1)
    }

    @Test("a server-side transcript error discards the id and resubmits on retry")
    func transcriptErrorResubmits() async throws {
        let container = try TestContainer.inMemory()
        let fixture = try RecordingFixture(container: container)
        defer { fixture.cleanUp() }

        let provider = ScriptedProvider(pollSteps: [.response(TranscriptFixtures.failed())])
        let job = TranscriptionJob.forTest(
            fixture: fixture, provider: provider, matching: matching(["A": nil, "B": nil])
        )

        let status = await job.run()
        #expect(status.kind == .failed)
        #expect(status.failureMessage?.contains("upstream exploded") == true)

        let failed = try fixture.snapshot()
        // Re-polling this id would return the same error forever, so it goes;
        // the upload stays, so the retry costs one request, not the file.
        #expect(failed.assemblyTranscriptId == nil)
        #expect(failed.uploadedAudioURLString != nil)
        #expect(failed.rawResponseFile == nil)
        #expect(try await job.resumePlan() == .submit(uploadURL: failed.uploadedAudioURLString ?? ""))

        provider.createResult = .success("t-2")
        provider.setPollSteps([.response(TranscriptFixtures.completed(id: "t-2"))])
        #expect(await job.retry() == .done)
        #expect(provider.counts.upload == 1)
        #expect(provider.counts.create == 2)
    }

    @Test("a 404 on poll also discards the id")
    func notFoundDiscardsID() {
        #expect(TranscriptionJob.discardsTranscriptID(TranscriptionError.notFound(message: nil)))
        #expect(TranscriptionJob.discardsTranscriptID(TranscriptionError.transcriptFailed(message: nil)))
        #expect(!TranscriptionJob.discardsTranscriptID(TranscriptionError.transport(description: "x")))
        #expect(!TranscriptionJob.discardsTranscriptID(TranscriptionError.pollingTimedOut(transcriptID: "t")))
        #expect(!TranscriptionJob.discardsTranscriptID(TranscriptionError.rateLimited(retryAfter: 1)))
    }

    @Test("a failure while matching retries with no network at all")
    func matchingFailureRetriesOffline() async throws {
        let container = try TestContainer.inMemory()
        let fixture = try RecordingFixture(container: container)
        defer { fixture.cleanUp() }

        let provider = ScriptedProvider(pollSteps: [.response(TranscriptFixtures.completed())])
        let matcher = StubSpeakerMatching(failingWith: MatchingBlewUp())
        let job = TranscriptionJob.forTest(fixture: fixture, provider: provider, matching: matcher)

        let status = await job.run()
        #expect(status.kind == .failed)
        #expect(status.failureMessage == "the embedder fell over")

        // The transcript is already on disk, so the retry is free.
        let failed = try fixture.snapshot()
        #expect(failed.rawResponseFile == RawTranscriptStore.defaultFileName)
        let plan = try await job.resumePlan()
        #expect(plan == .reprocess)
        #expect(!plan.usesNetwork)

        let networkBefore = provider.counts
        matcher.setHandler { _, transcript, _ in
            transcript.speakerLabels.map {
                SpeakerIdentification(
                    speaker: $0, spans: [], meetsTarget: true,
                    clusterEmbedding: TestVectors.unit(seed: 3),
                    match: SpeakerMatch(verdict: .unknown, best: nil, runnerUp: nil, threshold: 0.62)
                )
            }
        }
        #expect(await job.retry() == .done)
        // Not one further request: no upload, no submit, no poll.
        #expect(provider.counts == networkBefore)
        #expect(try fixture.snapshot().utteranceCount == 3)
    }

    @Test("the failure message is the actionable one, not a raw enum dump")
    func failureMessageIsReadable() async throws {
        let container = try TestContainer.inMemory()
        let fixture = try RecordingFixture(container: container)
        defer { fixture.cleanUp() }

        let provider = ScriptedProvider(uploadResult: .failure(.missingAPIKey))
        let job = TranscriptionJob.forTest(
            fixture: fixture, provider: provider, matching: matching([:])
        )

        let status = await job.run()
        let message = try #require(status.failureMessage)
        // Names the environment variable and where the app keeps the key, so
        // the person reading it in the library can act on it.
        #expect(message.contains("ASSEMBLYAI_API_KEY"))
        #expect(message.contains("Keychain"))
        #expect(!message.contains("missingAPIKey"))
    }
}

// MARK: - Resume

@Suite("Transcription job: relaunch resume")
struct TranscriptionJobResumeTests {

    @Test("a job left mid-poll resumes by transcript id, not by re-uploading")
    func resumesFromPersistedTranscriptID() async throws {
        let container = try TestContainer.inMemory()
        // Exactly what the store looks like after the app quits mid-poll.
        let fixture = try RecordingFixture(
            container: container,
            status: .transcribing,
            configure: { recording in
                recording.assemblyTranscriptId = "t-99"
                recording.uploadedAudioURLString = "https://cdn.assemblyai.com/upload/earlier"
            }
        )
        defer { fixture.cleanUp() }

        let provider = ScriptedProvider(pollSteps: [.response(TranscriptFixtures.completed(id: "t-99"))])
        let job = TranscriptionJob.forTest(
            fixture: fixture, provider: provider, matching: matching(["A": nil, "B": nil])
        )

        #expect(try await job.resumePlan() == .poll(transcriptID: "t-99"))
        #expect(await job.run() == .done)

        #expect(provider.counts.upload == 0)
        #expect(provider.counts.create == 0)
        #expect(provider.counts.poll == 1)
        #expect(try fixture.snapshot().status == .done)
    }

    @Test("cancellation leaves the row mid-flight so the next launch resumes")
    func cancellationLeavesStateResumable() async throws {
        let container = try TestContainer.inMemory()
        let fixture = try RecordingFixture(container: container)
        defer { fixture.cleanUp() }

        let provider = ScriptedProvider(pollSteps: [
            .response(TranscriptFixtures.inProgress(status: .processing)),
            .cancel
        ])
        let job = TranscriptionJob.forTest(
            fixture: fixture, provider: provider, matching: matching([:])
        )

        let status = await job.run()
        // Not failed — nothing went wrong, we just stopped.
        #expect(status == .transcribing)

        let snapshot = try fixture.snapshot()
        #expect(snapshot.status == .transcribing)
        #expect(snapshot.assemblyTranscriptId == "t-1")
        #expect(snapshot.status.isInFlight)
        #expect(try await job.resumePlan() == .poll(transcriptID: "t-1"))
    }

    @Test("in-flight recordings are discoverable on relaunch and resume to done")
    func relaunchSweep() async throws {
        let container = try TestContainer.inMemory()
        let fixture = try RecordingFixture(
            container: container,
            status: .queued,
            configure: { $0.assemblyTranscriptId = "t-77" }
        )
        defer { fixture.cleanUp() }

        let pending = try ModelContext(container).inFlightRecordings()
        #expect(pending.map(\.id) == [fixture.id])

        let provider = ScriptedProvider(pollSteps: [.response(TranscriptFixtures.completed(id: "t-77"))])
        let job = TranscriptionJob.forTest(
            fixture: fixture, provider: provider, matching: matching(["A": nil, "B": nil])
        )
        #expect(await job.run() == .done)
        #expect(try ModelContext(container).inFlightRecordings().isEmpty)
    }

    @Test("the resume plan is a pure function of the row plus what is on disk")
    func planIsPure() async throws {
        let container = try TestContainer.inMemory()
        let fixture = try RecordingFixture(container: container)
        defer { fixture.cleanUp() }
        let root = fixture.root.url

        var snapshot = try fixture.snapshot()
        #expect(TranscriptionJob.plan(for: snapshot, libraryRoot: root) == .upload)

        snapshot.uploadedAudioURLString = "https://cdn/x"
        #expect(TranscriptionJob.plan(for: snapshot, libraryRoot: root) == .submit(uploadURL: "https://cdn/x"))

        snapshot.assemblyTranscriptId = "t-5"
        #expect(TranscriptionJob.plan(for: snapshot, libraryRoot: root) == .poll(transcriptID: "t-5"))

        // A finished transcript on disk outranks every network route.
        try fixture.writeRawTranscript(TranscriptFixtures.completed())
        #expect(TranscriptionJob.plan(for: snapshot, libraryRoot: root) == .reprocess)

        snapshot.status = .done
        #expect(TranscriptionJob.plan(for: snapshot, libraryRoot: root) == .alreadyDone)
    }

    @Test("an unfinished file on disk does not masquerade as re-processable")
    func incompleteRawIsNotAPlan() async throws {
        let container = try TestContainer.inMemory()
        let fixture = try RecordingFixture(
            container: container,
            status: .failed(message: "stopped"),
            configure: { $0.assemblyTranscriptId = "t-1" }
        )
        defer { fixture.cleanUp() }

        // The body a mid-flight poll leaves behind.
        try fixture.writeRawTranscript(TranscriptFixtures.inProgress(status: .processing))

        let snapshot = try fixture.snapshot()
        #expect(TranscriptionJob.plan(for: snapshot, libraryRoot: fixture.root.url)
            == .poll(transcriptID: "t-1"))
    }
}

// MARK: - Re-processing

@Suite("Transcription job: re-process without a network")
struct TranscriptionJobReprocessTests {

    /// A recording whose transcript is already saved and whose job failed.
    private func stagedFixture(_ container: ModelContainer) throws -> RecordingFixture {
        let fixture = try RecordingFixture(
            container: container,
            status: .failed(message: "the embedder fell over"),
            configure: { recording in
                recording.assemblyTranscriptId = "t-1"
                recording.uploadedAudioURLString = "https://cdn.assemblyai.com/upload/fixture"
                recording.rawResponseFile = RawTranscriptStore.defaultFileName
            }
        )
        try fixture.writeRawTranscript(TranscriptFixtures.completed())
        return fixture
    }

    @Test("re-processing rebuilds utterances and matching with zero requests")
    func reprocessIsOffline() async throws {
        let container = try TestContainer.inMemory()
        let fixture = try stagedFixture(container)
        defer { fixture.cleanUp() }

        // This provider throws on every network call, so "offline" is enforced
        // rather than merely counted.
        let provider = ScriptedProvider.offline()
        let aliceID = try makePerson(container, name: "Alice")
        let job = TranscriptionJob.forTest(
            fixture: fixture,
            provider: provider,
            matching: matching(["A": ("Alice", aliceID, 0.88), "B": nil])
        )

        #expect(await job.reprocess() == .done)
        #expect(provider.counts == (upload: 0, create: 0, poll: 0))

        let snapshot = try fixture.snapshot()
        #expect(snapshot.status == .done)
        #expect(snapshot.utteranceCount == 3)
        #expect(snapshot.speakerSlotCount == 2)
        #expect(snapshot.participantNames == ["Alice"])
    }

    @Test("a plain retry picks the offline route by itself")
    func retryPrefersReprocess() async throws {
        let container = try TestContainer.inMemory()
        let fixture = try stagedFixture(container)
        defer { fixture.cleanUp() }

        let provider = ScriptedProvider.offline()
        let job = TranscriptionJob.forTest(
            fixture: fixture, provider: provider, matching: matching(["A": nil, "B": nil])
        )

        #expect(try await job.resumePlan() == .reprocess)
        #expect(await job.retry() == .done)
        #expect(provider.counts == (upload: 0, create: 0, poll: 0))
    }

    @Test("re-processing replaces old rows rather than accumulating them")
    func reprocessReplacesRows() async throws {
        let container = try TestContainer.inMemory()
        let fixture = try stagedFixture(container)
        defer { fixture.cleanUp() }

        let job = TranscriptionJob.forTest(
            fixture: fixture,
            provider: ScriptedProvider.offline(),
            matching: matching(["A": nil, "B": nil])
        )
        #expect(await job.reprocess() == .done)
        #expect(await job.reprocess() == .done)

        let context = ModelContext(container)
        #expect(try context.fetch(FetchDescriptor<Utterance>()).count == 3)
        #expect(try context.fetch(FetchDescriptor<SpeakerSlot>()).count == 2)
    }

    @Test("a human's confirmed speaker survives a re-process")
    func confirmedSlotsSurvive() async throws {
        let container = try TestContainer.inMemory()
        let fixture = try stagedFixture(container)
        defer { fixture.cleanUp() }

        let job = TranscriptionJob.forTest(
            fixture: fixture,
            provider: ScriptedProvider.offline(),
            matching: matching(["A": nil, "B": nil])
        )
        #expect(await job.reprocess() == .done)

        // The user names the unknown speaker A.
        let bobID = try makePerson(container, name: "Bob")
        try fixture.mutate { recording, context in
            let slot = try #require(recording.orderedSpeakerSlots.first)
            let bob = try #require(try context.person(id: bobID))
            slot.assign(bob, confirmed: true)
        }

        // A later re-process runs the matcher again and disagrees.
        #expect(await job.reprocess() == .done)

        try fixture.withRecording { recording in
            let a = try #require(recording.orderedSpeakerSlots.first)
            #expect(a.person?.name == "Bob")
            #expect(a.isConfirmed)
            #expect(a.unknownIndex == nil)
        }
    }

    @Test("re-processing with nothing saved fails with a clear message")
    func reprocessWithoutFile() async throws {
        let container = try TestContainer.inMemory()
        let fixture = try RecordingFixture(container: container, status: .failed(message: "x"))
        defer { fixture.cleanUp() }

        let job = TranscriptionJob.forTest(
            fixture: fixture, provider: ScriptedProvider.offline(), matching: matching([:])
        )
        let status = await job.reprocess()
        #expect(status.kind == .failed)
        #expect(status.failureMessage?.contains("No saved transcript to re-process") == true)
    }

    @Test("re-processing an unfinished response refuses and says why")
    func reprocessIncomplete() async throws {
        let container = try TestContainer.inMemory()
        let fixture = try RecordingFixture(
            container: container,
            status: .failed(message: "x"),
            configure: { $0.rawResponseFile = RawTranscriptStore.defaultFileName }
        )
        defer { fixture.cleanUp() }
        try fixture.writeRawTranscript(TranscriptFixtures.inProgress(status: .processing))

        let job = TranscriptionJob.forTest(
            fixture: fixture, provider: ScriptedProvider.offline(), matching: matching([:])
        )
        let status = await job.reprocess()
        #expect(status.kind == .failed)
        #expect(status.failureMessage?.contains("is not finished") == true)
        #expect(status.failureMessage?.contains("processing") == true)
    }
}

// MARK: - The real pipeline through the same seam

@Suite("Transcription job drives the real speaker-ID pipeline")
struct TranscriptionJobRealPipelineTests {

    private static let sampleRate: Double = 16_000

    /// Two speakers: A loud (0–12 s), B quiet (15–27 s). Loudness stands in
    /// for voice identity, exactly as in the Phase-1 pipeline tests.
    private func writeMeeting(to url: URL) throws {
        try TestAudio.writeWAV(
            to: url, sampleRate: Self.sampleRate, channels: 1, seconds: 28
        ) { _, frame in
            let second = Double(frame) / Self.sampleRate
            let tone = Float(sin(2 * Double.pi * 220 * Double(frame) / Self.sampleRate))
            if second < 12 { return 0.5 * tone }
            if second >= 15, second < 27 { return 0.05 * tone }
            return 0
        }
    }

    @Test("a real SpeakerIdentifier resolves both speakers end to end")
    func realIdentifierThroughTheJob() async throws {
        let container = try TestContainer.inMemory()
        let fixture = try RecordingFixture(
            container: container,
            title: "Meeting",
            audioExtension: "wav",
            writeAudio: { try self.writeMeeting(to: $0) }
        )
        defer { fixture.cleanUp() }

        let alice = TestVectors.unit(seed: 1)
        let bob = TestVectors.unit(seed: 2)

        // Profiles live in SwiftData, and the job reaches them through the
        // ProfileSource protocol — the app's real configuration.
        let profiles = SwiftDataProfileSource(container: container)
        _ = try await profiles.foldIn(alice, intoProfileNamed: "Alice", source: .enrollment)
        _ = try await profiles.foldIn(bob, intoProfileNamed: "Bob", source: .enrollment)

        let identifier = SpeakerIdentifier(
            embedder: StubEmbedder { TestAudio.rms($0) > 0.2 ? alice : bob }
        )

        let response = Fixture.transcript(
            audioDuration: 28,
            utterances: [
                Fixture.utterance(speaker: "A", start: 0, end: 11_500, wordCount: 12),
                Fixture.utterance(speaker: "B", start: 15_000, end: 26_500, wordCount: 12)
            ]
        )
        let provider = ScriptedProvider(pollSteps: [.response(response)])

        let job = TranscriptionJob.forTest(
            fixture: fixture,
            provider: provider,
            matching: identifier,
            profiles: profiles
        )

        #expect(await job.run() == .done)

        try fixture.withRecording { recording in
            let slots = recording.orderedSpeakerSlots
            #expect(slots.map(\.diarizedSpeaker) == ["A", "B"])
            #expect(slots.map { $0.person?.name } == ["Alice", "Bob"])
            #expect(slots.allSatisfy { $0.hasClusterEmbedding })
            #expect(slots.allSatisfy { ($0.matchScore ?? 0) >= ClusterMatcher.defaultThreshold })
            #expect(recording.participantNames == ["Alice", "Bob"])
        }
    }

    @Test("naming an unknown speaker later folds its saved embedding into a profile")
    func unknownSpeakerLearnsLater() async throws {
        // The spec's third acceptance criterion, at the persistence layer: an
        // unknown voice is flagged, and naming it *afterwards* — from the
        // stored cluster embedding, with no audio and no re-run — teaches the
        // profile.
        let container = try TestContainer.inMemory()
        let fixture = try RecordingFixture(container: container)
        defer { fixture.cleanUp() }

        let provider = ScriptedProvider(pollSteps: [.response(TranscriptFixtures.completed())])
        let profiles = SwiftDataProfileSource(container: container)
        let job = TranscriptionJob.forTest(
            fixture: fixture,
            provider: provider,
            matching: matching(["A": nil, "B": nil]),
            profiles: profiles
        )
        #expect(await job.run() == .done)

        // Weeks later: the user names speaker A.
        let stored: [Float] = try fixture.withRecording { recording in
            let slot = try #require(recording.orderedSpeakerSlots.first)
            #expect(slot.isUnknown)
            return slot.clusterEmbedding
        }
        #expect(!stored.isEmpty)

        let outcome = try await profiles.foldIn(stored, intoProfileNamed: "Carol", source: .autolearn)
        #expect(outcome.created)
        #expect(outcome.stored)

        // The next recording of that voice now matches Carol.
        let library = try await profiles.library()
        let verdict = ClusterMatcher().match(cluster: stored, in: library)
        #expect(verdict.verdict == .matched)
        #expect(verdict.name == "Carol")
    }
}

// MARK: - Subscribe-and-start

/// `start(_:)` exists because `events()` cannot serve the caller that is about
/// to *restart* a job. `events()` replays the current state and finishes the
/// stream when that state is terminal — right for an observer, and a trap for
/// a retry: the row is `failed` at the moment of subscription, so the caller
/// would attach to an already-finished stream and never see the run it just
/// asked for. These tests pin both halves of that contract.
///
/// Every test here consumes the stream to completion, so "the stream finishes"
/// is asserted by the test returning at all. The time limits turn a regression
/// into a failure rather than a suite that hangs forever.
@Suite("Transcription job: subscribe and start in one step")
struct TranscriptionJobStartTests {

    @Test("start() delivers every transition of the run it begins", .timeLimit(.minutes(1)))
    func deliversWholeRun() async throws {
        let container = try TestContainer.inMemory()
        let fixture = try RecordingFixture(container: container)
        defer { fixture.cleanUp() }

        let provider = ScriptedProvider(pollSteps: [
            .response(TranscriptFixtures.inProgress(status: .queued)),
            .response(TranscriptFixtures.completed())
        ])
        let job = TranscriptionJob.forTest(
            fixture: fixture, provider: provider, matching: matching(["A": nil, "B": nil])
        )

        let stream = await job.start()
        var events: [TranscriptionJobEvent] = []
        for await event in stream { events.append(event) }

        // Subscription happens before the run can emit, so the first real
        // transition is the first thing the caller sees — nothing is lost to a
        // race between starting and subscribing.
        #expect(statusPath(events) == [.uploading, .queued, .transcribing, .matching, .done])
        #expect(events.last?.status == .done)
        #expect(try fixture.snapshot().status == .done)
    }

    @Test("retrying a failed job streams the new run, not the old failure", .timeLimit(.minutes(1)))
    func retryDoesNotReplayTheFailure() async throws {
        let container = try TestContainer.inMemory()
        // Staged as a run that uploaded, then failed before a transcript id
        // existed — so the retry resubmits without re-uploading.
        let fixture = try RecordingFixture(
            container: container,
            status: .failed(message: "the network went away"),
            configure: { $0.uploadedAudioURLString = "https://cdn.assemblyai.com/upload/fixture" }
        )
        defer { fixture.cleanUp() }

        // The trap, demonstrated: a plain `events()` subscription on this row
        // hands back a stream that is already finished. This loop completes
        // immediately, having seen only the stale failure.
        let observer = TranscriptionJob.forTest(
            fixture: fixture,
            provider: ScriptedProvider.offline(),
            matching: StubSpeakerMatching(failingWith: MatchingBlewUp())
        )
        var replayed: [TranscriptionJobEvent] = []
        for await event in await observer.events() { replayed.append(event) }
        #expect(replayed.map(\.status.kind) == [.failed])

        // `start(.retry)` instead: the failure is cleared and the whole run is
        // reported, because subscribing and starting are one atomic step.
        let provider = ScriptedProvider(pollSteps: [.response(TranscriptFixtures.completed())])
        let job = TranscriptionJob.forTest(
            fixture: fixture, provider: provider, matching: matching(["A": nil, "B": nil])
        )

        let stream = await job.start(.retry)
        var events: [TranscriptionJobEvent] = []
        for await event in stream { events.append(event) }

        #expect(events.first?.status.kind != .failed)
        #expect(statusPath(events) == [.queued, .transcribing, .matching, .done])
        #expect(events.last?.status == .done)
        // Retry never re-records and, here, never re-uploads either.
        #expect(provider.counts.upload == 0)
        #expect(provider.counts.create == 1)
        #expect(try fixture.snapshot().status == .done)
    }

    @Test("the stream finishes even when the run emits nothing", .timeLimit(.minutes(1)))
    func alreadyDoneStillFinishes() async throws {
        let container = try TestContainer.inMemory()
        let fixture = try RecordingFixture(container: container, status: .done)
        defer { fixture.cleanUp() }

        // `.alreadyDone` returns without emitting a single event. Without
        // `conclude(_:)` closing it out, this loop would never return and the
        // app's status store would hold a job that looks forever busy.
        let provider = ScriptedProvider.offline()
        let matcher = StubSpeakerMatching(failingWith: MatchingBlewUp())
        let job = TranscriptionJob.forTest(fixture: fixture, provider: provider, matching: matcher)

        let stream = await job.start()
        var events: [TranscriptionJobEvent] = []
        for await event in stream { events.append(event) }

        #expect(events.map(\.status) == [.done])
        #expect(provider.counts == (upload: 0, create: 0, poll: 0))
        #expect(matcher.calls == 0)
        #expect(try fixture.snapshot().status == .done)
    }

    @Test("start(.reprocess) rebuilds from the saved response with no network", .timeLimit(.minutes(1)))
    func reprocessMode() async throws {
        let container = try TestContainer.inMemory()
        let fixture = try RecordingFixture(container: container, status: .done)
        defer { fixture.cleanUp() }
        try fixture.writeRawTranscript(TranscriptFixtures.completed())
        try fixture.mutate { recording, _ in
            recording.rawResponseFile = RawTranscriptStore.defaultFileName
        }

        let aliceID = try makePerson(container, name: "Alice")
        let provider = ScriptedProvider.offline()
        let job = TranscriptionJob.forTest(
            fixture: fixture,
            provider: provider,
            matching: matching(["A": ("Alice", aliceID, 0.93), "B": nil])
        )

        let stream = await job.start(.reprocess)
        var events: [TranscriptionJobEvent] = []
        for await event in stream { events.append(event) }

        #expect(statusPath(events) == [.matching, .done])
        #expect(provider.counts == (upload: 0, create: 0, poll: 0))

        let snapshot = try fixture.snapshot()
        #expect(snapshot.status == .done)
        #expect(snapshot.utteranceCount == 3)
        #expect(snapshot.participantNames == ["Alice"])
    }
}
