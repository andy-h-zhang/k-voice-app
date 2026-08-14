import AVFoundation
import Foundation
import Testing

@testable import KVoiceCore

/// The whole spec §3 pipeline — select → extract → embed → average → match —
/// driven end to end against synthetic audio and a stub embedder.
///
/// No model download, no network, no API key: `StubEmbedder` stands in for
/// `FluidAudioEmbedder`, which is exactly why `SpeakerEmbedder` is a protocol.
@Suite("Speaker identifier pipeline")
struct SpeakerIdentifierTests {

    private static let sampleRate: Double = 16_000

    /// Two-speaker meeting: A is loud (0–12 s), B is quiet (15–27 s).
    /// Loudness is the stand-in for voice identity the stub keys on.
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

    private func meetingTranscript() -> TranscriptResponse {
        Fixture.transcript(
            audioDuration: 28,
            utterances: [
                Fixture.utterance(speaker: "A", start: 0, end: 11_500, wordCount: 12),
                Fixture.utterance(speaker: "B", start: 15_000, end: 26_500, wordCount: 12)
            ]
        )
    }

    /// Routes loud audio to Alice's vector and quiet audio to Bob's.
    private func makeEmbedder(alice: [Float], bob: [Float]) -> StubEmbedder {
        StubEmbedder { samples in
            TestAudio.rms(samples) > 0.2 ? alice : bob
        }
    }

    private func library(alice: [Float], bob: [Float]) -> ProfileLibrary {
        var library = ProfileLibrary()
        let a = library.upsert(name: "Alice")
        library.profiles[a].foldIn(alice, source: .enrollment)
        let b = library.upsert(name: "Bob")
        library.profiles[b].foldIn(bob, source: .enrollment)
        return library
    }

    @Test("names both speakers when profiles exist")
    func identifiesBothSpeakers() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }

        let audio = directory.file("meeting.wav")
        try writeMeeting(to: audio)

        let alice = TestVectors.unit(seed: 1)
        let bob = TestVectors.unit(seed: 2)

        let identifier = SpeakerIdentifier(embedder: makeEmbedder(alice: alice, bob: bob))
        let results = try await identifier.identify(
            audioURL: audio,
            transcript: meetingTranscript(),
            library: library(alice: alice, bob: bob)
        )

        #expect(results.count == 2)

        let a = try #require(results.first { $0.speaker == "A" })
        #expect(a.match?.verdict == .matched)
        #expect(a.match?.name == "Alice")
        #expect(a.warnings.isEmpty)
        #expect(a.clusterEmbedding != nil)

        let b = try #require(results.first { $0.speaker == "B" })
        #expect(b.match?.verdict == .matched)
        #expect(b.match?.name == "Bob")
    }

    @Test("a voice with no profile is flagged unknown")
    func flagsUnknownVoice() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }

        let audio = directory.file("meeting.wav")
        try writeMeeting(to: audio)

        let alice = TestVectors.unit(seed: 1)
        let stranger = TestVectors.unit(seed: 42)

        // Only Alice is enrolled; the quiet speaker maps to an unenrolled vector.
        var library = ProfileLibrary()
        let index = library.upsert(name: "Alice")
        library.profiles[index].foldIn(alice, source: .enrollment)

        let identifier = SpeakerIdentifier(embedder: makeEmbedder(alice: alice, bob: stranger))
        let results = try await identifier.identify(
            audioURL: audio,
            transcript: meetingTranscript(),
            library: library
        )

        #expect(try #require(results.first { $0.speaker == "A" }).match?.verdict == .matched)

        let b = try #require(results.first { $0.speaker == "B" })
        #expect(b.match?.verdict == .unknown)
        #expect(b.match?.name == nil)
        // The near miss is still reported, which is what threshold tuning needs.
        #expect(b.match?.best?.name == "Alice")
    }

    @Test("the cluster embedding is the unit-length average of the span embeddings")
    func clusterEmbeddingIsNormalizedAverage() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }

        let audio = directory.file("meeting.wav")
        try writeMeeting(to: audio)

        let alice = TestVectors.unit(seed: 1)
        let identifier = SpeakerIdentifier(embedder: StubEmbedder(constant: alice))

        let results = try await identifier.identify(
            audioURL: audio,
            transcript: meetingTranscript(),
            library: ProfileLibrary()
        )

        let cluster = try #require(results.first?.clusterEmbedding)
        #expect(abs(VectorMath.l2Norm(cluster) - 1) < 1e-5)
        // Every span returned the same vector, so the average is that vector.
        #expect(isSameDirection(cluster, alice))
    }

    @Test("a failing span is skipped with a warning instead of failing the run")
    func spanFailureIsNonFatal() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }

        let audio = directory.file("meeting.wav")
        try writeMeeting(to: audio)

        let alice = TestVectors.unit(seed: 1)
        // The very first embed call throws; the rest succeed.
        let embedder = StubEmbedder(
            failures: [0: .audioTooShort(sampleCount: 10, minimum: 16_000)],
            rule: { _ in alice }
        )

        // A speaks twice, so losing one span still leaves a usable cluster.
        let transcript = Fixture.transcript(utterances: [
            Fixture.utterance(speaker: "A", start: 0, end: 5_600, wordCount: 6),
            Fixture.utterance(speaker: "A", start: 6_000, end: 11_600, wordCount: 6),
            Fixture.utterance(speaker: "B", start: 15_000, end: 26_500, wordCount: 12)
        ])

        let identifier = SpeakerIdentifier(embedder: embedder)
        let results = try await identifier.identify(
            audioURL: audio,
            transcript: transcript,
            library: ProfileLibrary()
        )

        let a = try #require(results.first { $0.speaker == "A" })
        #expect(a.warnings.count == 1)
        #expect(a.spans.count == 1)
        // One span was lost, so the evidence is thinner than the selector planned.
        #expect(!a.meetsTarget)
        // The surviving span still produced a usable cluster.
        #expect(a.clusterEmbedding != nil)
    }

    @Test("a speaker with no clean audio yields no embedding and an explanatory warning")
    func speakerWithoutCleanAudio() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }

        let audio = directory.file("meeting.wav")
        try writeMeeting(to: audio)

        // B's entire turn is overlapped by C, so B has no clean span.
        let transcript = Fixture.transcript(utterances: [
            Fixture.utterance(speaker: "A", start: 0, end: 11_500, wordCount: 12),
            Fixture.utterance(speaker: "B", start: 15_000, end: 24_000, wordCount: 9),
            TranscriptResponse.Utterance(
                speaker: "C",
                text: "talking over",
                start: 15_000,
                end: 24_000,
                words: [Fixture.word("over", 15_000, 24_000, speaker: "C")]
            )
        ])

        let identifier = SpeakerIdentifier(embedder: StubEmbedder(constant: TestVectors.unit(seed: 1)))
        let results = try await identifier.identify(
            audioURL: audio,
            transcript: transcript,
            library: ProfileLibrary()
        )

        let b = try #require(results.first { $0.speaker == "B" })
        #expect(b.clusterEmbedding == nil)
        #expect(b.match == nil)
        #expect(b.spans.isEmpty)
        #expect(!b.warnings.isEmpty)
    }

    /// Spec §4: naming a speaker folds that cluster into the person's profile,
    /// so the next recording recognizes them. This is the CLI's `--learn`.
    @Test("folding a cluster into a profile makes the next match succeed")
    func autoLearnClosesTheLoop() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }

        let audio = directory.file("meeting.wav")
        try writeMeeting(to: audio)

        let alice = TestVectors.unit(seed: 1)
        let newcomer = TestVectors.unit(seed: 77)
        let identifier = SpeakerIdentifier(embedder: makeEmbedder(alice: alice, bob: newcomer))

        var library = ProfileLibrary()
        let index = library.upsert(name: "Alice")
        library.profiles[index].foldIn(alice, source: .enrollment)

        // First pass: B is a stranger.
        let before = try await identifier.identify(
            audioURL: audio, transcript: meetingTranscript(), library: library
        )
        let b = try #require(before.first { $0.speaker == "B" })
        #expect(b.match?.verdict == .unknown)

        // The user names them; the cluster is folded in as auto-learned.
        let cluster = try #require(b.clusterEmbedding)
        let carolIndex = library.upsert(name: "Carol")
        library.profiles[carolIndex].foldIn(cluster, source: .autolearn)

        // Second pass: recognized.
        let after = try await identifier.identify(
            audioURL: audio, transcript: meetingTranscript(), library: library
        )
        let recognized = try #require(after.first { $0.speaker == "B" })
        #expect(recognized.match?.verdict == .matched)
        #expect(recognized.match?.name == "Carol")
        #expect(library.profiles[carolIndex].embeddingCount(source: .autolearn) == 1)
    }

    @Test("enrollment embeddings are produced one per window")
    func enrollmentWindows() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }

        // 12 s of speech → two 5 s windows plus a 2 s remainder.
        let clip = directory.file("alice.wav")
        try TestAudio.writeWAV(
            to: clip, sampleRate: Self.sampleRate, channels: 1, seconds: 12,
            sample: TestAudio.sine(frequency: 220, sampleRate: Self.sampleRate)
        )

        let identifier = SpeakerIdentifier(embedder: StubEmbedder(constant: TestVectors.unit(seed: 1)))
        let vectors = try await identifier.enrollmentEmbeddings(clips: [clip], windowSeconds: 5)

        #expect(vectors.count == 3)
        #expect(vectors.allSatisfy { abs(VectorMath.l2Norm($0) - 1) < 1e-5 })
    }

    @Test("the pipeline is deterministic across runs")
    func deterministic() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }

        let audio = directory.file("meeting.wav")
        try writeMeeting(to: audio)

        let alice = TestVectors.unit(seed: 1)
        let bob = TestVectors.unit(seed: 2)
        let transcript = meetingTranscript()
        let library = library(alice: alice, bob: bob)

        let first = try await SpeakerIdentifier(embedder: makeEmbedder(alice: alice, bob: bob))
            .identify(audioURL: audio, transcript: transcript, library: library)
        let second = try await SpeakerIdentifier(embedder: makeEmbedder(alice: alice, bob: bob))
            .identify(audioURL: audio, transcript: transcript, library: library)

        #expect(first.map(\.speaker) == second.map(\.speaker))
        #expect(first.map { $0.match?.name } == second.map { $0.match?.name })
        for (lhs, rhs) in zip(first, second) {
            #expect(lhs.spans == rhs.spans)
        }
    }
}
