import AVFoundation
import Foundation
import Testing
@testable import KVoiceCore

/// The recorder's lifecycle rules and output-format contract, tested without
/// touching a microphone.
@Suite("Recording state machine")
struct RecordingStateTests {
    @Test("a fresh source can only start, or be stopped before it ever started")
    func idleTransitions() {
        #expect(RecordingState.idle.canTransition(to: .recording))
        #expect(RecordingState.idle.canTransition(to: .stopping))
        #expect(!RecordingState.idle.canTransition(to: .paused))
        #expect(!RecordingState.idle.canTransition(to: .stopped))
    }

    @Test("recording can pause or stop, but cannot go back to idle")
    func recordingTransitions() {
        #expect(RecordingState.recording.canTransition(to: .paused))
        #expect(RecordingState.recording.canTransition(to: .stopping))
        #expect(!RecordingState.recording.canTransition(to: .idle))
        #expect(!RecordingState.recording.canTransition(to: .stopped))
    }

    @Test("paused can resume or stop")
    func pausedTransitions() {
        #expect(RecordingState.paused.canTransition(to: .recording))
        #expect(RecordingState.paused.canTransition(to: .stopping))
        #expect(!RecordingState.paused.canTransition(to: .idle))
    }

    /// Repeated `pause()` calls and repeated device-loss notifications must
    /// not be fatal — they land on the state they are already in.
    @Test("staying put is legal for recording and paused, so repeats are idempotent")
    func selfTransitionsAreIdempotent() {
        #expect(RecordingState.recording.canTransition(to: .recording))
        #expect(RecordingState.paused.canTransition(to: .paused))
    }

    @Test("stopped is terminal")
    func stoppedIsTerminal() {
        #expect(RecordingState.stopped.isTerminal)
        for state in RecordingState.allCases {
            #expect(!RecordingState.stopped.canTransition(to: state))
        }
    }

    @Test("stopping only leads to stopped")
    func stoppingLeadsOnlyToStopped() {
        #expect(RecordingState.stopping.canTransition(to: .stopped))
        #expect(!RecordingState.stopping.canTransition(to: .recording))
        #expect(!RecordingState.stopping.canTransition(to: .paused))
    }

    @Test("only recording writes frames to disk")
    func onlyRecordingWritesFrames() {
        #expect(RecordingState.recording.writesFrames)
        for state in RecordingState.allCases where state != .recording {
            #expect(!state.writesFrames)
        }
    }

    /// Pause keeps the file open — that is the whole point of pause/resume
    /// producing one continuous recording.
    @Test("recording and paused both hold the file open")
    func recordingAndPausedHoldTheFileOpen() {
        #expect(RecordingState.recording.holdsOpenFile)
        #expect(RecordingState.paused.holdsOpenFile)
        #expect(!RecordingState.idle.holdsOpenFile)
        #expect(!RecordingState.stopped.holdsOpenFile)
    }
}

@Suite("Recording format")
struct RecordingFormatTests {
    @Test("the default is 48 kHz mono AAC in an .m4a")
    func defaultFormatMatchesTheSpec() {
        let format = RecordingFormat.aacMono48k
        #expect(format.sampleRate == 48_000)
        #expect(format.channelCount == 1)
        #expect(format.fileExtension == "m4a")
    }

    @Test("settings carry the AAC format ID, rate, channels and bit rate")
    func settingsDescribeAAC() throws {
        let settings = RecordingFormat.aacMono48k.settings

        let formatID = try #require(settings[AVFormatIDKey] as? AudioFormatID)
        #expect(formatID == kAudioFormatMPEG4AAC)
        #expect(settings[AVSampleRateKey] as? Double == 48_000)
        #expect(settings[AVNumberOfChannelsKey] as? UInt32 == 1)
        #expect(settings[AVEncoderBitRateKey] as? Int == 96_000)
    }

    @Test("the bit-rate-free fallback keeps everything else")
    func fallbackSettingsDropOnlyTheBitRate() {
        let settings = RecordingFormat.aacMono48k.settingsWithoutBitRate
        #expect(settings[AVEncoderBitRateKey] == nil)
        #expect(settings[AVSampleRateKey] as? Double == 48_000)
        #expect(settings[AVNumberOfChannelsKey] as? UInt32 == 1)
    }

    @Test("the processing format is deinterleaved 32-bit float at the target rate")
    func processingFormatIsFloat32() throws {
        let format = try #require(RecordingFormat.aacMono48k.processingFormat)
        #expect(format.commonFormat == .pcmFormatFloat32)
        #expect(format.sampleRate == 48_000)
        #expect(format.channelCount == 1)
        #expect(!format.isInterleaved)
    }

    /// The container is inferred from the path extension, so a mismatch has
    /// to fail loudly rather than write an AAC stream into a ".wav".
    @Test("creating a file with the wrong extension throws before touching disk")
    func wrongExtensionThrows() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kvoice-format-\(UUID().uuidString).wav")

        #expect(throws: RecordingError.fileExtensionMismatch(expected: "m4a", actual: "wav")) {
            _ = try RecordingFormat.aacMono48k.makeAudioFile(at: url)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("a custom format round-trips its values")
    func customFormat() {
        let format = RecordingFormat(sampleRate: 44_100, channelCount: 2, bitRate: 128_000)
        #expect(format.sampleRate == 44_100)
        #expect(format.channelCount == 2)
        #expect(format.settings[AVEncoderBitRateKey] as? Int == 128_000)
    }
}
