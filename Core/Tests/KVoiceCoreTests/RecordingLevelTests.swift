import AVFoundation
import Foundation
import Testing
@testable import KVoiceCore

/// Level-meter math. Pure sample arithmetic — no engine, no hardware.
@Suite("Recording level metering")
struct RecordingLevelTests {
    private let tolerance: Float = 0.0001

    // MARK: - RMS

    @Test("RMS of an empty buffer is zero, not NaN")
    func rmsOfEmptyBufferIsZero() {
        #expect(AudioLevel.rms([]) == 0)
    }

    @Test("RMS of digital silence is zero")
    func rmsOfSilenceIsZero() {
        #expect(AudioLevel.rms([Float](repeating: 0, count: 512)) == 0)
    }

    @Test("RMS of a full-scale constant is one")
    func rmsOfFullScaleConstantIsOne() {
        #expect(abs(AudioLevel.rms([1, 1, 1, 1]) - 1) < tolerance)
    }

    @Test("RMS uses magnitude, so sign does not matter")
    func rmsIgnoresSign() {
        #expect(abs(AudioLevel.rms([0.5, -0.5, 0.5, -0.5]) - 0.5) < tolerance)
    }

    /// The classic sanity check: a full-scale sine reads 1/√2 ≈ 0.707, not 1.
    @Test("RMS of a full-scale sine is 1/sqrt(2)")
    func rmsOfFullScaleSine() {
        let sampleCount = 4800
        let samples = (0..<sampleCount).map { index in
            sin(2 * Float.pi * 100 * Float(index) / 48_000)
        }
        let expected = Float(1 / 2.0.squareRoot())
        #expect(abs(AudioLevel.rms(samples) - expected) < 0.001)
    }

    @Test("non-finite samples are skipped rather than poisoning the result")
    func rmsSkipsNonFiniteSamples() {
        #expect(abs(AudioLevel.rms([1, .nan, 1, .infinity, 1]) - 1) < tolerance)
    }

    @Test("a buffer of only non-finite samples reads zero")
    func rmsOfAllNonFiniteSamplesIsZero() {
        #expect(AudioLevel.rms([.nan, .infinity, -.infinity]) == 0)
    }

    // MARK: - dBFS

    @Test("full scale is 0 dBFS")
    func fullScaleIsZeroDecibels() {
        #expect(abs(AudioLevel.decibels(rms: 1)) < tolerance)
    }

    @Test("half amplitude is about -6 dBFS")
    func halfAmplitudeIsMinusSixDecibels() {
        #expect(abs(AudioLevel.decibels(rms: 0.5) - -6.0206) < 0.001)
    }

    @Test("silence clamps to the silence floor instead of -infinity")
    func silenceClampsToFloor() {
        #expect(AudioLevel.decibels(rms: 0) == AudioLevel.silenceDB)
        #expect(AudioLevel.decibels(rms: -1) == AudioLevel.silenceDB)
        #expect(AudioLevel.decibels(rms: .nan) == AudioLevel.silenceDB)
    }

    // MARK: - Normalization

    @Test("0 dBFS maps to 1 and the floor maps to 0")
    func normalizationEndpoints() {
        #expect(abs(AudioLevel.normalized(decibels: 0) - 1) < tolerance)
        #expect(abs(AudioLevel.normalized(decibels: AudioLevel.defaultFloorDB)) < tolerance)
    }

    @Test("half way to the floor maps to the middle of the meter")
    func normalizationMidpoint() {
        #expect(abs(AudioLevel.normalized(decibels: -30) - 0.5) < tolerance)
    }

    @Test("levels below the floor clamp to zero, above full scale to one")
    func normalizationClamps() {
        #expect(AudioLevel.normalized(decibels: -200) == 0)
        #expect(AudioLevel.normalized(decibels: 12) == 1)
        #expect(AudioLevel.normalized(decibels: .nan) == 0)
    }

    @Test("a custom floor rescales the meter")
    func normalizationHonorsCustomFloor() {
        #expect(abs(AudioLevel.normalized(decibels: -20, floor: -40) - 0.5) < tolerance)
    }

    @Test("meter level stays inside 0...1 and rises with amplitude")
    func meterLevelIsMonotonicAndBounded() {
        let amplitudes: [Float] = [0, 0.001, 0.01, 0.1, 0.5, 1.0]
        let levels = amplitudes.map { amplitude in
            AudioLevel.meterLevel(of: [Float](repeating: amplitude, count: 128))
        }

        for level in levels {
            #expect(level >= 0 && level <= 1)
        }
        for (quieter, louder) in zip(levels, levels.dropFirst()) {
            #expect(louder >= quieter)
        }
        #expect(levels.first == 0)
        #expect(abs(levels.last! - 1) < tolerance)
    }

    // MARK: - PCM buffers

    @Test("RMS reads deinterleaved float buffers across every channel")
    func rmsOfDeinterleavedFloatBuffer() throws {
        let format = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)
        )
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64))
        buffer.frameLength = 64

        let channels = try #require(buffer.floatChannelData)
        for channel in 0..<2 {
            for frame in 0..<64 {
                // One loud channel, one silent: RMS is sqrt((1 + 0) / 2).
                channels[channel][frame] = channel == 0 ? 1 : 0
            }
        }

        #expect(abs(AudioLevel.rms(of: buffer) - Float((0.5 as Double).squareRoot())) < tolerance)
    }

    @Test("RMS reads interleaved float buffers")
    func rmsOfInterleavedFloatBuffer() throws {
        let format = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)
        )
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32))
        buffer.frameLength = 32

        let samples = try #require(buffer.floatChannelData)[0]
        for index in 0..<(32 * 2) {
            samples[index] = 0.5
        }

        #expect(abs(AudioLevel.rms(of: buffer) - 0.5) < tolerance)
    }

    @Test("RMS reads 16-bit integer buffers, normalized to 0...1")
    func rmsOfInt16Buffer() throws {
        let format = try #require(
            AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: false)
        )
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
        buffer.frameLength = 16

        let samples = try #require(buffer.int16ChannelData)[0]
        for index in 0..<16 {
            samples[index] = Int16.max
        }

        #expect(abs(AudioLevel.rms(of: buffer) - 1) < 0.001)
    }

    @Test("an empty buffer reads zero")
    func rmsOfZeroLengthBuffer() throws {
        let format = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)
        )
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
        buffer.frameLength = 0

        #expect(AudioLevel.rms(of: buffer) == 0)
    }

    // MARK: - Smoothing

    @Test("the meter rises quickly toward a louder reading")
    func smootherRisesWithAttack() {
        var smoother = LevelSmoother(attack: 0.5, release: 0.1)
        #expect(abs(smoother.update(1) - 0.5) < tolerance)
        #expect(abs(smoother.update(1) - 0.75) < tolerance)
    }

    @Test("the meter falls slowly toward a quieter reading")
    func smootherFallsWithRelease() {
        var smoother = LevelSmoother(attack: 0.5, release: 0.1, initialValue: 1)
        #expect(abs(smoother.update(0) - 0.9) < tolerance)
        #expect(abs(smoother.update(0) - 0.81) < tolerance)
    }

    @Test("the meter settles exactly on its target rather than trailing forever")
    func smootherConvergesToTarget() {
        var smoother = LevelSmoother(attack: 0.6, release: 0.2, initialValue: 1)
        for _ in 0..<200 { smoother.update(0) }
        #expect(smoother.value == 0)
    }

    @Test("readings outside 0...1 and non-finite readings are clamped")
    func smootherClampsInput() {
        var smoother = LevelSmoother(attack: 1, release: 1)
        #expect(smoother.update(5) == 1)
        #expect(smoother.update(-3) == 0)
        #expect(smoother.update(.nan) == 0)
    }

    @Test("reset returns the meter to zero")
    func smootherResets() {
        var smoother = LevelSmoother(initialValue: 1)
        smoother.reset()
        #expect(smoother.value == 0)
    }
}
