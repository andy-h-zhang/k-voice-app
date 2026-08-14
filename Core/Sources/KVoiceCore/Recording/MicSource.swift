import AVFoundation
import Foundation

/// Microphone capture on `AVAudioEngine`, encoding to AAC `.m4a` as it goes.
///
/// ## Shape of the pipeline
///
/// ```
/// input node tap ──▶ AVAudioConverter ──▶ AVAudioFile (AAC .m4a)
///     (hw format)     (48 kHz mono F32)     streamed to disk
///          └────────▶ AudioLevel.meterLevel ──▶ levelStream (~15 Hz)
/// ```
///
/// Every tap buffer is converted and written immediately, so memory use is
/// flat regardless of length — a 2-hour meeting costs the same RAM as a
/// 2-second one. Nothing is buffered in memory to be flushed at the end,
/// which is also why a recording interrupted by a crash or a yanked device
/// stays playable up to its last written frame.
///
/// ## Threading
///
/// Tap callbacks arrive on a CoreAudio thread. All mutable state lives behind
/// one lock; engine teardown (`removeTap`/`stop`) happens *outside* that lock
/// because it blocks until in-flight tap callbacks return, and those
/// callbacks want the lock.
///
/// ## Lifecycle
///
/// Single-use: `start` → (`pause`/`resume`)* → `stop`. `stop()` finalizes the
/// file and finishes both streams.
public final class MicSource: AudioSource, @unchecked Sendable {
    // MARK: - Configuration

    /// UID of the input device to capture from, or `nil` for the system
    /// default. Honoured on macOS only; iOS routes input through
    /// `AVAudioSession`.
    public let inputDeviceUID: String?

    /// How long to wait for an answer to a microphone-access prompt before
    /// giving up. Generous by default (a user has to notice and click the
    /// system prompt); short-circuited by `speakerlab record`, which should
    /// fail fast rather than sit there.
    public let permissionRequestTimeout: TimeInterval

    /// Meter emission rate — inside the 10–20 Hz band a level meter needs to
    /// look continuous without flooding the consumer.
    private static let levelInterval: TimeInterval = 1.0 / 15.0

    /// ~85 ms of audio at 48 kHz: large enough to keep per-buffer overhead
    /// negligible over two hours, small enough for a responsive meter.
    private static let tapBufferSize: AVAudioFrameCount = 4096

    // MARK: - Streams

    public let levelStream: AsyncStream<Float>
    public let events: AsyncStream<RecordingEvent>

    private let levelContinuation: AsyncStream<Float>.Continuation
    private let eventContinuation: AsyncStream<RecordingEvent>.Continuation

    // MARK: - Guarded state

    private let lock = UnfairLock()
    private var state: RecordingState = .idle
    private var engine: AVAudioEngine?
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var downmixFormat: AVAudioFormat?
    private var downmixSourceFormat: AVAudioFormat?
    private var targetFormat: AVAudioFormat?
    private var outputURL: URL?
    private var writtenFrames: Int64 = 0
    private var recordedSampleRate: Double = 0
    private var recordedChannelCount: UInt32 = 0
    private var lastLevelEmit: TimeInterval = 0
    private var tapInstalled = false
    private var observers: [NSObjectProtocol] = []

    // MARK: - Init

    /// - Parameters:
    ///   - inputDeviceUID: macOS input device UID from
    ///     ``AudioDeviceManager/inputDevices()``, or `nil` for the default.
    ///   - permissionRequestTimeout: Seconds to wait for an answer to the
    ///     microphone-access prompt.
    public init(inputDeviceUID: String? = nil, permissionRequestTimeout: TimeInterval = 60) {
        self.inputDeviceUID = inputDeviceUID
        self.permissionRequestTimeout = permissionRequestTimeout

        // Newest-value-only: a meter that falls behind should show "now",
        // not replay a backlog.
        let level = AsyncStream.makeStream(of: Float.self, bufferingPolicy: .bufferingNewest(1))
        self.levelStream = level.stream
        self.levelContinuation = level.continuation

        let event = AsyncStream.makeStream(of: RecordingEvent.self, bufferingPolicy: .bufferingNewest(32))
        self.events = event.stream
        self.eventContinuation = event.continuation
    }

    deinit {
        for token in observers { NotificationCenter.default.removeObserver(token) }
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0) }
        if engine?.isRunning == true { engine?.stop() }
        file = nil
        levelContinuation.finish()
        eventContinuation.finish()
    }

    // MARK: - Introspection

    /// Current lifecycle state.
    public var recordingState: RecordingState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    public var recordedDuration: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard recordedSampleRate > 0 else { return 0 }
        return Double(writtenFrames) / recordedSampleRate
    }

    /// The file being written, once `start` has succeeded.
    public var fileURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return outputURL
    }

    // MARK: - AudioSource

    public func start(writingTo url: URL, format: RecordingFormat = .aacMono48k) async throws {
        // Ask before touching hardware, and never while holding the lock.
        try await ensureMicrophoneAccess()

        lock.lock()
        let current = state
        guard current == .idle else {
            lock.unlock()
            throw current.isTerminal ? RecordingError.sourceAlreadyStopped : RecordingError.alreadyRecording
        }
        lock.unlock()

        // Nothing below is shared until it is published under the lock, so
        // a failure here leaves the source reusable in `.idle`.
        let engine = AVAudioEngine()

        #if os(macOS)
        if let inputDeviceUID {
            // Must precede reading the input format: the format follows the
            // selected device.
            try AudioDeviceManager.setInputDevice(uid: inputDeviceUID, on: engine)
        }
        #endif

        let input = engine.inputNode
        guard let inputFormat = Self.usableInputFormat(of: input) else {
            throw RecordingError.noInputDevice
        }

        let file = try format.makeAudioFile(at: url)
        let target = file.processingFormat

        // Multi-channel input is mixed to mono before conversion, so the
        // converter is built for what it will actually be fed. Failing here
        // is much better than failing on the first captured buffer.
        let converterInputFormat = inputFormat.channelCount > 1
            ? (Self.monoFormat(matching: inputFormat) ?? inputFormat)
            : inputFormat

        guard let converter = Self.makeConverter(from: converterInputFormat, to: target) else {
            // Don't leave a zero-byte .m4a behind on a failed start.
            try? FileManager.default.removeItem(at: url)
            throw RecordingError.converterUnavailable(
                from: converterInputFormat.description,
                to: target.description
            )
        }

        lock.lock()
        self.engine = engine
        self.file = file
        self.converter = converter
        self.converterInputFormat = converterInputFormat
        self.downmixFormat = nil
        self.downmixSourceFormat = nil
        self.targetFormat = target
        self.outputURL = url
        self.writtenFrames = 0
        self.recordedSampleRate = target.sampleRate
        self.recordedChannelCount = target.channelCount
        self.lastLevelEmit = 0
        self.state = .recording
        lock.unlock()

        registerObservers(for: engine)

        do {
            try installTap(on: input, format: inputFormat)
            try startEngine(engine)
        } catch {
            removeObservers()
            input.removeTap(onBus: 0)
            lock.lock()
            self.state = .idle
            self.engine = nil
            self.file = nil          // closes the empty file before deleting it
            self.converter = nil
            self.converterInputFormat = nil
            self.downmixFormat = nil
            self.downmixSourceFormat = nil
            self.targetFormat = nil
            self.outputURL = nil
            self.tapInstalled = false
            self.recordedSampleRate = 0
            lock.unlock()
            try? FileManager.default.removeItem(at: url)
            throw error
        }

        emit(.started)
    }

    public func pause() async {
        lock.lock()
        guard state == .recording else {
            lock.unlock()
            return
        }
        state = .paused
        lock.unlock()
        emit(.paused(.user))
    }

    public func resume() async throws {
        lock.lock()
        switch state {
        case .recording:
            lock.unlock()
            return                                  // already running; no-op
        case .paused:
            break
        default:
            lock.unlock()
            throw RecordingError.notPaused
        }
        let engine = self.engine
        let needsTap = !tapInstalled
        lock.unlock()

        guard let engine else { throw RecordingError.notPaused }

        // After a device change the tap was torn down and the input format
        // may be different, so re-derive both.
        if needsTap || !engine.isRunning {
            let input = engine.inputNode
            guard let inputFormat = Self.usableInputFormat(of: input) else {
                throw RecordingError.noInputDevice
            }
            if needsTap {
                try installTap(on: input, format: inputFormat)
            }
            if !engine.isRunning {
                try startEngine(engine)
            }
        }

        lock.lock()
        state = .recording
        lock.unlock()
        emit(.resumed)
    }

    @discardableResult
    public func stop() async -> RecordingSummary? {
        lock.lock()
        guard !state.isTerminal, state.canTransition(to: .stopping) else {
            lock.unlock()
            return nil
        }
        let producedFile = state.holdsOpenFile
        state = .stopping

        let engineToStop = engine
        let hadTap = tapInstalled
        let url = outputURL
        let frames = writtenFrames
        let sampleRate = recordedSampleRate
        let channelCount = recordedChannelCount

        engine = nil
        // Releasing the last reference closes the file and writes the MPEG-4
        // `moov` atom — this is the step that makes the .m4a playable. Doing
        // it under the lock guarantees no tap callback is mid-write.
        file = nil
        converter = nil
        converterInputFormat = nil
        downmixFormat = nil
        downmixSourceFormat = nil
        targetFormat = nil
        tapInstalled = false
        lock.unlock()

        removeObservers()

        // Outside the lock: both calls block until in-flight tap callbacks
        // return, and those callbacks take the lock.
        if hadTap { engineToStop?.inputNode.removeTap(onBus: 0) }
        if engineToStop?.isRunning == true { engineToStop?.stop() }

        lock.lock()
        state = .stopped
        lock.unlock()

        defer {
            levelContinuation.finish()
            eventContinuation.finish()
        }

        guard producedFile, let url, sampleRate > 0 else { return nil }

        let summary = RecordingSummary(
            url: url,
            duration: Double(frames) / sampleRate,
            frameCount: frames,
            sampleRate: sampleRate,
            channelCount: channelCount
        )
        emit(.stopped(summary))
        return summary
    }

    // MARK: - Capture

    private func installTap(on input: AVAudioInputNode, format: AVAudioFormat) throws {
        input.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: format) { [weak self] buffer, _ in
            self?.handleTap(buffer)
        }
        lock.lock()
        tapInstalled = true
        lock.unlock()
    }

    private func startEngine(_ engine: AVAudioEngine) throws {
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw RecordingError.engineStartFailed(error.localizedDescription)
        }
    }

    /// Converts and writes one tap buffer. Runs on a CoreAudio thread.
    private func handleTap(_ buffer: AVAudioPCMBuffer) {
        // Metered from the raw input buffer, so the meter shows what the
        // microphone hears rather than what survived conversion.
        let level = AudioLevel.meterLevel(of: buffer)

        var levelToEmit: Float?
        var failure: Error?

        lock.lock()
        let currentState = state
        guard currentState == .recording || currentState == .paused else {
            lock.unlock()
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        if now - lastLevelEmit >= Self.levelInterval {
            lastLevelEmit = now
            // A paused meter reads zero: nothing is being recorded.
            levelToEmit = currentState == .recording ? level : 0
        }

        if currentState == .recording, let file, let target = targetFormat {
            do {
                // Mix every channel down first: AVAudioConverter does *not*
                // downmix, it keeps channel 0 and drops the rest, which on a
                // stereo interface or the built-in multi-channel mic array
                // would silently throw away part of the room.
                let source = downmixIfNeeded(buffer)
                let converter = try converterForInput(source.format, target: target)
                if let converted = try Self.convert(source, using: converter, to: target),
                   converted.frameLength > 0 {
                    try file.write(from: converted)
                    writtenFrames += Int64(converted.frameLength)
                }
            } catch {
                failure = error
            }
        }
        lock.unlock()

        if let levelToEmit { levelContinuation.yield(levelToEmit) }
        if let failure { handleWriteFailure(failure) }
    }

    /// Mixes a multi-channel tap buffer down to mono, or returns it
    /// unchanged when there is nothing to mix.
    ///
    /// - Important: callers must hold `lock`.
    private func downmixIfNeeded(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard buffer.format.channelCount > 1 else { return buffer }

        if downmixSourceFormat != buffer.format {
            downmixFormat = Self.monoFormat(matching: buffer.format)
            downmixSourceFormat = buffer.format
        }

        guard let monoFormat = downmixFormat,
              let mixed = Self.downmixToMono(buffer, to: monoFormat)
        else {
            // Unreadable layout: let the converter do what it can rather
            // than dropping the buffer entirely.
            return buffer
        }
        return mixed
    }

    /// The mono float format matching `format`'s sample rate.
    static func monoFormat(matching format: AVAudioFormat) -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: format.sampleRate,
            channels: 1,
            interleaved: false
        )
    }

    /// Averages every channel into one.
    ///
    /// `AVAudioConverter` will happily convert 2 channels to 1, but it does
    /// so by taking the first channel — verified by measurement, not by the
    /// documentation. Averaging keeps every microphone in the recording,
    /// which is what a meeting recorder needs.
    ///
    /// - Returns: A mono buffer, or `nil` if the sample layout is not one
    ///   that can be read directly (the caller then falls back).
    static func downmixToMono(_ buffer: AVAudioPCMBuffer, to monoFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 1 else { return nil }
        guard monoFormat.channelCount == 1,
              monoFormat.commonFormat == .pcmFormatFloat32,
              !monoFormat.isInterleaved,
              monoFormat.sampleRate == buffer.format.sampleRate
        else { return nil }

        guard let output = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(frameCount)),
              let destination = output.floatChannelData?[0]
        else { return nil }
        output.frameLength = AVAudioFrameCount(frameCount)

        let isInterleaved = buffer.format.isInterleaved
        let scale = 1 / Float(channelCount)

        if let floatData = buffer.floatChannelData {
            for frame in 0..<frameCount {
                var sum: Float = 0
                for channel in 0..<channelCount {
                    let value = isInterleaved
                        ? floatData[0][frame * channelCount + channel]
                        : floatData[channel][frame]
                    // A non-finite sample would poison the whole file.
                    if value.isFinite { sum += value }
                }
                destination[frame] = sum * scale
            }
            return output
        }

        if let intData = buffer.int16ChannelData {
            let intScale = scale / Float(Int16.max)
            for frame in 0..<frameCount {
                var sum: Float = 0
                for channel in 0..<channelCount {
                    let value = isInterleaved
                        ? intData[0][frame * channelCount + channel]
                        : intData[channel][frame]
                    sum += Float(value)
                }
                destination[frame] = sum * intScale
            }
            return output
        }

        return nil
    }

    /// Returns a converter for `inputFormat`, rebuilding it if the hardware
    /// format changed underneath us (device switch, sample-rate change).
    ///
    /// - Important: callers must hold `lock`.
    private func converterForInput(
        _ inputFormat: AVAudioFormat,
        target: AVAudioFormat
    ) throws -> AVAudioConverter {
        if let converter, let existing = converterInputFormat, existing == inputFormat {
            return converter
        }
        guard let rebuilt = Self.makeConverter(from: inputFormat, to: target) else {
            throw RecordingError.converterUnavailable(
                from: inputFormat.description,
                to: target.description
            )
        }
        converter = rebuilt
        converterInputFormat = inputFormat
        return rebuilt
    }

    static func makeConverter(
        from inputFormat: AVAudioFormat,
        to target: AVAudioFormat
    ) -> AVAudioConverter? {
        guard let converter = AVAudioConverter(from: inputFormat, to: target) else { return nil }
        // Sample-rate conversion runs once per buffer on a non-realtime
        // thread; quality is cheap here and the audio feeds speaker
        // embeddings downstream.
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        return converter
    }

    /// Resamples/downmixes one buffer into the file's format.
    ///
    /// Internal rather than private so the conversion path — the part of
    /// capture that has nothing to do with hardware — can be tested against
    /// synthesized buffers.
    static func convert(
        _ input: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to target: AVAudioFormat
    ) throws -> AVAudioPCMBuffer? {
        guard input.frameLength > 0 else { return nil }

        let ratio = target.sampleRate / input.format.sampleRate
        // Headroom for the resampler's internal latency and rounding.
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw RecordingError.conversionFailed("could not allocate a \(capacity)-frame output buffer")
        }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return input
        }

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            return output.frameLength > 0 ? output : nil
        case .error:
            throw RecordingError.conversionFailed(
                conversionError?.localizedDescription ?? "unknown converter failure"
            )
        @unknown default:
            return output.frameLength > 0 ? output : nil
        }
    }

    private func handleWriteFailure(_ error: Error) {
        let recordingError = (error as? RecordingError) ?? .writeFailed(error.localizedDescription)

        lock.lock()
        let wasRecording = state == .recording
        if wasRecording { state = .paused }
        lock.unlock()

        // Auto-pause rather than tear down: everything already written is
        // still a valid file, and the caller may be able to recover (freed
        // disk space, remounted volume) and resume.
        if wasRecording { emit(.paused(.writeFailure)) }
        emit(.failed(recordingError))
    }

    /// The format an input tap must be installed with.
    ///
    /// `installTap` requires the bus's *output* format; a disconnected or
    /// not-yet-configured device reports 0 Hz / 0 channels, which is the
    /// signal that there is nothing to record from.
    private static func usableInputFormat(of node: AVAudioInputNode) -> AVAudioFormat? {
        let output = node.outputFormat(forBus: 0)
        if output.sampleRate > 0, output.channelCount > 0 { return output }
        let input = node.inputFormat(forBus: 0)
        if input.sampleRate > 0, input.channelCount > 0 { return input }
        return nil
    }

    // MARK: - Interruptions and device loss

    private func registerObservers(for engine: AVAudioEngine) {
        let center = NotificationCenter.default
        var tokens: [NSObjectProtocol] = []

        // `queue: nil` delivers on the posting thread. Deliberate: a CLI that
        // blocks its main thread while recording would never see a
        // `.main`-queued notification.
        tokens.append(
            center.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: nil
            ) { [weak self] _ in
                self?.handleConfigurationChange()
            }
        )

        #if os(iOS)
        tokens.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                self?.handleInterruption(notification)
            }
        )
        #endif

        lock.lock()
        observers = tokens
        lock.unlock()
    }

    private func removeObservers() {
        lock.lock()
        let tokens = observers
        observers = []
        lock.unlock()
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }

    /// The engine reconfigured itself — typically the input device was
    /// unplugged, switched, or changed sample rate.
    ///
    /// Capture is auto-paused and a typed error surfaced; the file stays open
    /// and valid to its last written frame. `resume()` rebuilds the tap
    /// against whatever device is available then.
    private func handleConfigurationChange() {
        lock.lock()
        guard state == .recording || state == .paused else {
            lock.unlock()
            return
        }
        let wasRecording = state == .recording
        state = .paused
        let engineRef = engine
        let hadTap = tapInstalled
        tapInstalled = false
        // The hardware format may have changed; force a rebuild on resume.
        converter = nil
        converterInputFormat = nil
        downmixFormat = nil
        downmixSourceFormat = nil
        lock.unlock()

        if hadTap { engineRef?.inputNode.removeTap(onBus: 0) }
        if engineRef?.isRunning == true { engineRef?.stop() }

        if wasRecording { emit(.paused(.deviceLost)) }
        emit(.failed(.inputDeviceDisconnected))
    }

    #if os(iOS)
    private func handleInterruption(_ notification: Notification) {
        guard
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }

        switch type {
        case .began:
            lock.lock()
            let wasRecording = state == .recording
            if wasRecording { state = .paused }
            lock.unlock()
            if wasRecording {
                emit(.paused(.interrupted))
                emit(.failed(.interrupted))
            }
        case .ended:
            // Resumption is the caller's decision — the user may have walked
            // away mid-call.
            break
        @unknown default:
            break
        }
    }
    #endif

    // MARK: - Permission

    private func ensureMicrophoneAccess() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            switch await Self.requestMicrophoneAccess(timeout: permissionRequestTimeout) {
            case .granted:
                return
            case .denied:
                throw RecordingError.microphonePermissionDenied
            case .timedOut:
                throw RecordingError.microphonePermissionRequestTimedOut
            }
        case .denied, .restricted:
            throw RecordingError.microphonePermissionDenied
        @unknown default:
            throw RecordingError.microphonePermissionDenied
        }
    }

    private enum PermissionOutcome {
        case granted, denied, timedOut
    }

    /// Requests microphone access, bounded by a timeout.
    ///
    /// A bundled app gets a system prompt and the user answers in seconds.
    /// A process the permission system has no identity for gets no prompt
    /// **and no callback** — verified by sampling a hung `speakerlab record`,
    /// whose task stayed suspended forever. The timeout turns that into a
    /// typed error with instructions instead of a hang.
    private static func requestMicrophoneAccess(timeout: TimeInterval) async -> PermissionOutcome {
        await withCheckedContinuation { continuation in
            let guardedResume = ResumeOnce()

            AVCaptureDevice.requestAccess(for: .audio) { granted in
                guard guardedResume.claim() else { return }
                continuation.resume(returning: granted ? .granted : .denied)
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + max(0, timeout)) {
                guard guardedResume.claim() else { return }
                continuation.resume(returning: .timedOut)
            }
        }
    }

    // MARK: - Events

    private func emit(_ event: RecordingEvent) {
        eventContinuation.yield(event)
    }
}

/// One-shot guard: whichever of two racing callbacks arrives first resumes
/// the continuation, and the loser is a no-op. Resuming twice would trap.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = UnfairLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}
