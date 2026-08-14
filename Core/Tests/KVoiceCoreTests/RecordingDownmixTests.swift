import AVFoundation
import Foundation
import Testing
@testable import KVoiceCore

/// Multi-channel input reaching a mono file.
///
/// These exist because of a measured surprise: `AVAudioConverter` converts
/// stereo to mono by **keeping channel 0 and discarding the rest**, not by
/// mixing. On a stereo interface — or the built-in microphone array, which
/// reports three input channels — that silently drops part of the room from
/// a meeting recording. `MicSource` therefore mixes down itself, and these
/// tests pin that behaviour.
@Suite("Recording downmix")
struct RecordingDownmixTests {
    private let tolerance: Float = 0.0001

    @Test("channels are averaged, not selected")
    func averagesChannelsRatherThanSelecting() throws {
        let format = try format(channels: 2)
        let buffer = try buffer(format: format, frames: 64) { channel, _ in
            channel == 0 ? 1.0 : -1.0
        }
        let monoFormat = try #require(MicSource.monoFormat(matching: format))

        let mixed = try #require(MicSource.downmixToMono(buffer, to: monoFormat))
        let samples = try #require(mixed.floatChannelData)[0]

        // Selecting channel 0 would give +1.0 here; averaging gives 0.
        #expect(abs(samples[0]) < tolerance)
        #expect(mixed.frameLength == 64)
        #expect(mixed.format.channelCount == 1)
    }

    @Test("a signal on one channel survives at proportional level")
    func signalOnOneChannelSurvives() throws {
        let format = try format(channels: 2)
        let buffer = try buffer(format: format, frames: 64) { channel, _ in
            channel == 0 ? 0.5 : 0.0
        }
        let monoFormat = try #require(MicSource.monoFormat(matching: format))

        let mixed = try #require(MicSource.downmixToMono(buffer, to: monoFormat))
        #expect(abs(try #require(mixed.floatChannelData)[0][0] - 0.25) < tolerance)
    }

    /// The regression that matters: audio arriving only on the right channel
    /// must not vanish. Channel-0 selection would produce silence.
    @Test("audio on the right channel alone is not dropped")
    func rightChannelIsNotDropped() throws {
        let format = try format(channels: 2)
        let buffer = try buffer(format: format, frames: 128) { channel, frame in
            channel == 1 ? sin(2 * .pi * 440 * Float(frame) / 48_000) : 0
        }
        let monoFormat = try #require(MicSource.monoFormat(matching: format))

        let mixed = try #require(MicSource.downmixToMono(buffer, to: monoFormat))
        #expect(AudioLevel.rms(of: mixed) > 0.1)
    }

    /// The built-in MacBook microphone reports three input channels.
    @Test("a three-channel microphone array is averaged across all channels")
    func threeChannelArrayIsAveraged() throws {
        let format = try format(channels: 3)
        let buffer = try buffer(format: format, frames: 32) { _, _ in 0.6 }
        let monoFormat = try #require(MicSource.monoFormat(matching: format))

        let mixed = try #require(MicSource.downmixToMono(buffer, to: monoFormat))
        #expect(abs(try #require(mixed.floatChannelData)[0][0] - 0.6) < tolerance)
    }

    @Test("interleaved buffers are mixed correctly")
    func interleavedBuffersAreMixed() throws {
        let format = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)
        )
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32))
        buffer.frameLength = 32
        let samples = try #require(buffer.floatChannelData)[0]
        for frame in 0..<32 {
            samples[frame * 2] = 1.0            // left
            samples[frame * 2 + 1] = 0.0        // right
        }
        let monoFormat = try #require(MicSource.monoFormat(matching: format))

        let mixed = try #require(MicSource.downmixToMono(buffer, to: monoFormat))
        #expect(abs(try #require(mixed.floatChannelData)[0][5] - 0.5) < tolerance)
    }

    @Test("16-bit integer buffers are mixed and normalized to float")
    func int16BuffersAreMixed() throws {
        let format = try #require(
            AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 2, interleaved: false)
        )
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32))
        buffer.frameLength = 32
        let channels = try #require(buffer.int16ChannelData)
        for frame in 0..<32 {
            channels[0][frame] = Int16.max
            channels[1][frame] = 0
        }
        let monoFormat = try #require(MicSource.monoFormat(matching: format))

        let mixed = try #require(MicSource.downmixToMono(buffer, to: monoFormat))
        #expect(abs(try #require(mixed.floatChannelData)[0][0] - 0.5) < 0.001)
        #expect(mixed.format.commonFormat == .pcmFormatFloat32)
    }

    @Test("a non-finite sample does not poison the mix")
    func nonFiniteSamplesAreIgnored() throws {
        let format = try format(channels: 2)
        let buffer = try buffer(format: format, frames: 8) { channel, _ in
            channel == 0 ? .nan : 1.0
        }
        let monoFormat = try #require(MicSource.monoFormat(matching: format))

        let mixed = try #require(MicSource.downmixToMono(buffer, to: monoFormat))
        let value = try #require(mixed.floatChannelData)[0][0]
        #expect(value.isFinite)
        #expect(abs(value - 0.5) < tolerance)
    }

    @Test("mono and empty buffers need no mixing")
    func monoAndEmptyBuffersAreSkipped() throws {
        let monoInput = try format(channels: 1)
        let monoFormat = try #require(MicSource.monoFormat(matching: monoInput))
        let monoBuffer = try buffer(format: monoInput, frames: 16) { _, _ in 0.5 }
        #expect(MicSource.downmixToMono(monoBuffer, to: monoFormat) == nil)

        let stereo = try format(channels: 2)
        let empty = try #require(AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 16))
        empty.frameLength = 0
        let stereoMonoFormat = try #require(MicSource.monoFormat(matching: stereo))
        #expect(MicSource.downmixToMono(empty, to: stereoMonoFormat) == nil)
    }

    @Test("the mono format keeps the input's sample rate for the resampler")
    func monoFormatKeepsSampleRate() throws {
        let format = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false)
        )
        let mono = try #require(MicSource.monoFormat(matching: format))

        #expect(mono.sampleRate == 44_100)
        #expect(mono.channelCount == 1)
        #expect(mono.commonFormat == .pcmFormatFloat32)
        #expect(!mono.isInterleaved)
    }

    /// End to end at the buffer level: a stereo 44.1 kHz buffer with content
    /// only on the right channel has to arrive in the 48 kHz mono file.
    @Test("right-channel-only audio survives downmix plus resampling")
    func rightChannelSurvivesTheWholeChain() throws {
        let inputFormat = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false)
        )
        let targetFormat = try #require(RecordingFormat.aacMono48k.processingFormat)
        let input = try buffer(format: inputFormat, frames: 4410) { channel, frame in
            channel == 1 ? 0.8 * sin(2 * .pi * 440 * Float(frame) / 44_100) : 0
        }

        let monoFormat = try #require(MicSource.monoFormat(matching: inputFormat))
        let mixed = try #require(MicSource.downmixToMono(input, to: monoFormat))
        let converter = try #require(MicSource.makeConverter(from: monoFormat, to: targetFormat))
        let converted = try #require(try MicSource.convert(mixed, using: converter, to: targetFormat))

        #expect(converted.format.sampleRate == 48_000)
        #expect(converted.format.channelCount == 1)
        #expect(AudioLevel.rms(of: converted) > 0.1)
    }

    // MARK: - Helpers

    private func format(channels: AVAudioChannelCount) throws -> AVAudioFormat {
        // The channels: convenience initializer only knows mono and stereo
        // layouts and returns nil beyond them, so anything wider needs an
        // explicit discrete layout — exactly what a multi-capsule
        // microphone array reports.
        guard channels > 2 else {
            return try #require(
                AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: 48_000,
                    channels: channels,
                    interleaved: false
                )
            )
        }

        let layout = try #require(
            AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels)
        )
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            interleaved: false,
            channelLayout: layout
        )
    }

    private func buffer(
        format: AVAudioFormat,
        frames: AVAudioFrameCount,
        sample: (Int, Int) -> Float
    ) throws -> AVAudioPCMBuffer {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channels = try #require(buffer.floatChannelData)
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<Int(frames) {
                channels[channel][frame] = sample(channel, frame)
            }
        }
        return buffer
    }
}
