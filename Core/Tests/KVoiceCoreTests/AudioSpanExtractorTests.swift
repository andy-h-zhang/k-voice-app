import AVFoundation
import Foundation
import Testing

@testable import KVoiceCore

/// Span extraction is tested against audio generated in the test itself, so
/// the expected content of every span is known exactly. No fixtures, no
/// network, no models.
@Suite("Audio span extraction")
struct AudioSpanExtractorTests {

    private let extractor = AudioSpanExtractor()

    @Test("reports the file duration")
    func duration() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }

        let url = directory.file("tone.wav")
        try TestAudio.writeWAV(
            to: url, sampleRate: 48_000, channels: 1, seconds: 3,
            sample: TestAudio.sine(frequency: 440, sampleRate: 48_000)
        )

        #expect(abs(try extractor.duration(of: url) - 3) < 0.01)
    }

    @Test("resamples a 48 kHz span down to 16 kHz mono")
    func resamplesTo16k() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }

        let url = directory.file("tone.wav")
        try TestAudio.writeWAV(
            to: url, sampleRate: 48_000, channels: 1, seconds: 3,
            sample: TestAudio.sine(frequency: 440, sampleRate: 48_000)
        )

        let samples = try extractor.samples(from: url, startSeconds: 1, endSeconds: 2)

        // One second at 16 kHz, allowing for the resampler's edge handling.
        #expect(abs(samples.count - 16_000) <= 128)
        // The tone survived the conversion (a 0.5-amplitude sine has RMS ≈ 0.354).
        #expect(TestAudio.rms(samples) > 0.25)
        let allFinite = samples.allSatisfy { $0.isFinite }
        #expect(allFinite)
    }

    @Test("a 16 kHz source passes through at exactly the requested length")
    func passesThroughAtTargetRate() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }

        let url = directory.file("tone16k.wav")
        try TestAudio.writeWAV(
            to: url, sampleRate: 16_000, channels: 1, seconds: 2,
            sample: TestAudio.sine(frequency: 300, sampleRate: 16_000)
        )

        let samples = try extractor.samples(from: url, startSeconds: 0.5, endSeconds: 1.5)
        #expect(samples.count == 16_000)
    }

    /// Channels are averaged before resampling; a signal that is exactly out
    /// of phase between L and R must cancel to silence.
    @Test("stereo is downmixed by averaging channels")
    func downmixesStereo() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }

        let url = directory.file("stereo.wav")
        try TestAudio.writeWAV(to: url, sampleRate: 16_000, channels: 2, seconds: 1) { channel, frame in
            let value = 0.5 * Float(sin(2 * Double.pi * 440 * Double(frame) / 16_000))
            return channel == 0 ? value : -value
        }

        let samples = try extractor.samples(from: url, startSeconds: 0, endSeconds: 1)
        #expect(TestAudio.rms(samples) < 1e-6)
    }

    @Test("stereo with identical channels keeps its amplitude")
    func downmixPreservesAmplitude() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }

        let url = directory.file("stereo-same.wav")
        try TestAudio.writeWAV(to: url, sampleRate: 16_000, channels: 2, seconds: 1) { _, frame in
            0.5 * Float(sin(2 * Double.pi * 440 * Double(frame) / 16_000))
        }

        let samples = try extractor.samples(from: url, startSeconds: 0, endSeconds: 1)
        #expect(abs(TestAudio.rms(samples) - 0.354) < 0.02)
    }

    @Test("an AudioSpan is read at the right offset")
    func readsFromAudioSpan() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }

        // Second 1 is silent; seconds 0 and 2 carry a tone.
        let url = directory.file("gated.wav")
        try TestAudio.writeWAV(to: url, sampleRate: 16_000, channels: 1, seconds: 3) { _, frame in
            let second = frame / 16_000
            guard second != 1 else { return 0 }
            return 0.5 * Float(sin(2 * Double.pi * 440 * Double(frame) / 16_000))
        }

        let silent = try extractor.samples(
            from: url,
            span: AudioSpan(startMs: 1_000, endMs: 2_000, voicedMs: 1_000)
        )
        let loud = try extractor.samples(
            from: url,
            span: AudioSpan(startMs: 2_000, endMs: 3_000, voicedMs: 1_000)
        )

        #expect(TestAudio.rms(silent) < 1e-6)
        #expect(TestAudio.rms(loud) > 0.25)
    }

    @Test("a span past the end of the file is clamped")
    func clampsToFileLength() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }

        let url = directory.file("short.wav")
        try TestAudio.writeWAV(
            to: url, sampleRate: 16_000, channels: 1, seconds: 1,
            sample: TestAudio.sine(frequency: 440, sampleRate: 16_000)
        )

        let samples = try extractor.samples(from: url, startSeconds: 0.5, endSeconds: 60)
        #expect(abs(samples.count - 8_000) <= 64)
    }

    @Test("an empty or inverted span is rejected")
    func rejectsEmptySpan() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }

        let url = directory.file("short.wav")
        try TestAudio.writeWAV(
            to: url, sampleRate: 16_000, channels: 1, seconds: 1,
            sample: TestAudio.sine(frequency: 440, sampleRate: 16_000)
        )

        #expect(throws: AudioSpanExtractionError.self) {
            try extractor.samples(from: url, startSeconds: 0.5, endSeconds: 0.5)
        }
        #expect(throws: AudioSpanExtractionError.self) {
            try extractor.samples(from: url, startSeconds: 0.9, endSeconds: 0.2)
        }
        #expect(throws: AudioSpanExtractionError.self) {
            try extractor.samples(from: url, startSeconds: 5, endSeconds: 6)
        }
    }

    @Test("a missing file is reported clearly")
    func missingFile() {
        #expect(throws: AudioSpanExtractionError.fileNotFound(url: URL(fileURLWithPath: "/tmp/does-not-exist.wav"))) {
            try extractor.samples(from: URL(fileURLWithPath: "/tmp/does-not-exist.wav"), startSeconds: 0, endSeconds: 1)
        }
    }

    @Test("reading the whole file returns every sample")
    func readsWholeFile() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }

        let url = directory.file("tone.wav")
        try TestAudio.writeWAV(
            to: url, sampleRate: 16_000, channels: 1, seconds: 2.5,
            sample: TestAudio.sine(frequency: 440, sampleRate: 16_000)
        )

        #expect(try extractor.samples(from: url).count == 40_000)
    }

    /// Chunked reading uses one converter across chunks; a long file must not
    /// come back short or discontinuous.
    @Test("a file longer than one read chunk resamples completely")
    func multiChunkResampling() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanUp() }

        // 5 s at 44.1 kHz = 220,500 frames, far more than one 16,384-frame chunk,
        // and a rate that does not divide evenly into 16 kHz.
        let url = directory.file("long.wav")
        try TestAudio.writeWAV(
            to: url, sampleRate: 44_100, channels: 1, seconds: 5,
            sample: TestAudio.sine(frequency: 440, sampleRate: 44_100)
        )

        let samples = try extractor.samples(from: url)

        #expect(abs(samples.count - 80_000) <= 256)
        #expect(TestAudio.rms(samples) > 0.25)
        let allFinite = samples.allSatisfy { $0.isFinite }
        #expect(allFinite)
    }

    // MARK: - Windowing (enrollment path)

    @Test("windows tile the buffer at the requested length")
    func windowsTileBuffer() {
        let samples = [Float](repeating: 0.1, count: 16_000 * 10)
        let windows = AudioSpanExtractor.windows(of: samples, sampleRate: 16_000, windowSeconds: 5)

        #expect(windows.count == 2)
        #expect(windows.allSatisfy { $0.count == 80_000 })
    }

    @Test("a trailing partial window is kept when it is long enough")
    func keepsUsableRemainder() {
        let samples = [Float](repeating: 0.1, count: 16_000 * 13)
        let windows = AudioSpanExtractor.windows(
            of: samples, sampleRate: 16_000, windowSeconds: 5, minWindowSeconds: 2
        )

        #expect(windows.count == 3)
        #expect(windows[2].count == 16_000 * 3)
    }

    @Test("a trailing partial window shorter than the floor is dropped")
    func dropsTooShortRemainder() {
        let samples = [Float](repeating: 0.1, count: 16_000 * 11)
        let windows = AudioSpanExtractor.windows(
            of: samples, sampleRate: 16_000, windowSeconds: 5, minWindowSeconds: 2
        )

        #expect(windows.count == 2)
    }

    @Test("a clip shorter than one window still produces one window")
    func shortClipYieldsOneWindow() {
        let samples = [Float](repeating: 0.1, count: 16_000 * 3)
        let windows = AudioSpanExtractor.windows(of: samples, sampleRate: 16_000, windowSeconds: 5)

        #expect(windows.count == 1)
        #expect(windows[0].count == 16_000 * 3)
    }

    @Test("an overlapping hop produces overlapping windows")
    func overlappingHop() {
        let samples = [Float](repeating: 0.1, count: 16_000 * 10)
        let windows = AudioSpanExtractor.windows(
            of: samples, sampleRate: 16_000, windowSeconds: 5, hopSeconds: 2.5
        )
        #expect(windows.count > 2)
    }

    @Test("empty input produces no windows")
    func emptyInput() {
        #expect(AudioSpanExtractor.windows(of: [], sampleRate: 16_000).isEmpty)
        #expect(AudioSpanExtractor.windows(of: [0.1], sampleRate: 16_000, windowSeconds: 0).isEmpty)
    }
}

@Suite("FluidAudio embedder windowing")
struct FluidAudioEmbedderWindowingTests {

    /// The CoreML model's waveform input is a fixed 160,000 samples — 10 s at
    /// 16 kHz. Longer audio would be silently truncated by the library, so the
    /// embedder windows it instead. Pure arithmetic: no model is loaded here.
    @Test("the model window is 10 seconds at 16 kHz")
    func modelWindowConstant() {
        #expect(FluidAudioEmbedder.modelWindowSamples == 160_000)
        #expect(FluidAudioEmbedder.embeddingDimension == 256)
    }

    @Test("audio at or under the window is a single window")
    func singleWindow() {
        #expect(FluidAudioEmbedder.windowRanges(sampleCount: 160_000) == [0..<160_000])
        #expect(FluidAudioEmbedder.windowRanges(sampleCount: 100_000) == [0..<100_000])
    }

    @Test("an exact multiple splits evenly")
    func exactMultiple() {
        #expect(FluidAudioEmbedder.windowRanges(sampleCount: 320_000) == [0..<160_000, 160_000..<320_000])
    }

    @Test("a usable remainder becomes its own window")
    func usableRemainder() {
        #expect(
            FluidAudioEmbedder.windowRanges(sampleCount: 200_000)
                == [0..<160_000, 160_000..<200_000]
        )
    }

    /// Rather than discarding the tail of a span, the final window is aligned
    /// to the end of the buffer, overlapping its predecessor.
    @Test("a too-short remainder is covered by a tail-aligned window")
    func tailAlignedWindow() {
        #expect(
            FluidAudioEmbedder.windowRanges(sampleCount: 170_000)
                == [0..<160_000, 10_000..<170_000]
        )
    }

    @Test("windows never exceed the model width and always cover the buffer")
    func invariants() {
        for count in [1, 16_000, 159_999, 160_001, 240_000, 500_000, 1_000_000] {
            let ranges = FluidAudioEmbedder.windowRanges(sampleCount: count)
            #expect(!ranges.isEmpty)
            #expect(ranges.allSatisfy { $0.count <= 160_000 })
            #expect(ranges.allSatisfy { $0.lowerBound >= 0 && $0.upperBound <= count })
            #expect(ranges.last?.upperBound == count)
        }
    }

    @Test("an empty buffer produces no windows")
    func emptyBuffer() {
        #expect(FluidAudioEmbedder.windowRanges(sampleCount: 0).isEmpty)
    }
}
