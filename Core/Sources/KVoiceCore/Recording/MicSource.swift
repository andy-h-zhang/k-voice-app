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

    /// How long to let a configuration change settle before deciding whether
    /// capture survived it.
    ///
    /// Long enough for several tap buffers (~85 ms each) to have arrived if the
    /// tap is still alive, short enough that a recording which really did stop
    /// loses a fraction of a second rather than a meeting.
    private static let configurationSettleDelay: TimeInterval = 0.3

    /// How quiet the tap must have been to count as stopped.
    ///
    /// Comfortably more than one buffer period and comfortably less than
    /// ``configurationSettleDelay``, so a live tap is never mistaken for a dead
    /// one merely because a buffer was late.
    private static let tapStaleThreshold: TimeInterval = 0.25

    /// How many rebuilds in a row are attempted before the recording is paused
    /// instead. A backstop, not the mechanism — see
    /// ``recoverIfCaptureStalled()``.
    private static let maxConsecutiveRecoveries = 6

    /// A rebuild more than this long after the previous one begins a fresh run,
    /// resetting the count above.
    private static let recoveryRunWindow: TimeInterval = 5

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
    private var recordedChannelCount: UInt32 = 0
    private var lastLevelEmit: TimeInterval = 0
    private var tapInstalled = false
    private var observers: [NSObjectProtocol] = []

    /// Uptime of the most recent tap callback — the evidence that capture is
    /// alive, and the only thing that can tell a configuration change which
    /// tore the graph down from one that merely announced itself.
    private var lastTapAt: TimeInterval = 0

    /// Consecutive rebuilds, and when the run of them began — the backstop
    /// against a rebuild that provokes the notification that triggered it.
    private var recoveryCount = 0
    private var recoveryRunStarted: TimeInterval = 0

    /// Frames written and the rate they were written at — behind their *own*
    /// lock, not `lock`.
    ///
    /// The record screen polls ``recordedDuration`` at 10 Hz on the main actor.
    /// While these counters lived behind `lock`, every one of those polls could
    /// block the main thread behind the tap's encode-and-write, and a main
    /// thread that stalls stops drawing the window. See ``RecordingCounters``.
    private let counters = RecordingCounters()

    /// The one place the `AVAudioEngine` graph is ever mutated.
    ///
    /// Serial, and every `installTap`/`removeTap`/`start()`/`stop()` goes
    /// through it. Two reasons, and the second is the one that bit:
    ///
    /// 1. `removeTap` and `AVAudioEngine.stop()` block until in-flight tap
    ///    callbacks return, so they must not run on a thread we do not own — a
    ///    CoreAudio notification thread, or whichever thread happened to release
    ///    the source's last reference, which is very often the main one.
    /// 2. `AVAudioEngine` is not safe to reconfigure from two threads at once.
    ///    Before this queue owned the graph, the configuration change posted by
    ///    bring-up tore the tap off on one thread while `start()` was still
    ///    inside `engine.start()` on another. Everything that touches the engine
    ///    now queues here, so a notification provoked by a start is handled
    ///    *after* that start has finished rather than in the middle of it.
    private let engineQueue = DispatchQueue(
        label: "ai.kizaki.kvoice.micsource.engine",
        qos: .userInitiated
    )

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

    /// Last-resort teardown for a source that was dropped without `stop()`.
    ///
    /// Everything here that can block is handed to ``engineQueue`` rather
    /// than run on whichever thread happened to release the last reference —
    /// and that thread is very often the main one, because the objects holding
    /// a source (a view model, the tasks observing its streams) are main-actor
    /// bound. `removeTap` and `stop()` block until in-flight tap callbacks
    /// return, so doing them inline is a main-thread stall of unbounded length.
    deinit {
        for token in observers { NotificationCenter.default.removeObserver(token) }

        let engineToStop = engine
        let fileToClose = file
        let hadTap = tapInstalled
        let queue = engineQueue

        engine = nil
        file = nil
        levelContinuation.finish()
        eventContinuation.finish()

        guard engineToStop != nil || fileToClose != nil else { return }
        queue.async {
            if hadTap { engineToStop?.inputNode.removeTap(onBus: 0) }
            if engineToStop?.isRunning == true { engineToStop?.stop() }
            // Ordering matters as much as the hop does: the file reference is
            // released only *after* the engine has stopped delivering buffers,
            // and releasing it is what writes the MPEG-4 `moov` atom that makes
            // the .m4a playable. `withExtendedLifetime` says so out loud rather
            // than relying on the reader to know that a captured value dies
            // with the closure.
            withExtendedLifetime(fileToClose) {}
        }
    }

    // MARK: - Introspection

    /// Current lifecycle state.
    public var recordingState: RecordingState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    /// Seconds of audio actually written.
    ///
    /// Safe to poll from the main thread: it reads ``counters``, whose lock is
    /// never held across the tap's encode-and-write, so this call cannot be
    /// blocked by disk I/O. That is a contract, not an incidental property —
    /// the record screen calls it ten times a second on the main actor.
    public var recordedDuration: TimeInterval {
        counters.duration
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
        //
        // Building the engine on ``engineQueue`` is what keeps the device
        // selection and the format read ordered against everything else that
        // touches the graph.
        //
        // The format read here is for the converter; the tap reads its own, at
        // the moment it is installed. It is still worth reading now: a source
        // and target with no converter between them should fail before a file is
        // created, not on the first buffer.
        let prepared = try await onEngineQueue { () -> (engine: AVAudioEngine, format: AVAudioFormat) in
            let engine = try self.makeConfiguredEngine()
            guard let inputFormat = Self.usableInputFormat(of: engine.inputNode) else {
                throw RecordingError.noInputDevice
            }
            return (engine, inputFormat)
        }
        let engine = prepared.engine
        let inputFormat = prepared.format

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
        self.recordedChannelCount = target.channelCount
        self.lastLevelEmit = 0
        self.lastTapAt = ProcessInfo.processInfo.systemUptime
        self.state = .recording
        lock.unlock()
        counters.begin(sampleRate: target.sampleRate)

        registerObservers(for: engine)

        do {
            // One block, so the configuration change that bring-up posts cannot
            // land between installing the tap and starting the engine: it is
            // dispatched to this same queue, so it waits until both are done.
            try await onEngineQueue { try self.beginCapture(on: engine) }
        } catch {
            removeObservers()
            await tearDownOnEngineQueue { engine.inputNode.removeTap(onBus: 0) }
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
            lock.unlock()
            counters.reset()
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
        lock.unlock()

        guard let engine else { throw RecordingError.notPaused }

        // After a device change the tap was torn down and the device may be a
        // different one, so capture is re-established from scratch — on the
        // engine queue, ordered behind any recovery still in flight, and reading
        // `tapInstalled` there rather than here so the answer cannot be stale by
        // the time it is used.
        try await onEngineQueue {
            self.lock.lock()
            let hadTap = self.tapInstalled
            self.lock.unlock()

            // A plain `pause()` left the tap installed and the engine running;
            // there is nothing to rebuild, and rebuilding would only open a gap.
            guard !hadTap || !engine.isRunning else { return }

            self.lock.lock()
            self.tapInstalled = false
            self.lock.unlock()

            // Replaced rather than restarted, for the same reason a recovery
            // replaces it: an engine that has been through a configuration
            // change misreports its input format, and `installTap` treats that
            // as fatal. See ``makeConfiguredEngine()``.
            self.removeObservers()
            if hadTap { engine.inputNode.removeTap(onBus: 0) }
            if engine.isRunning { engine.stop() }

            let replacement = try self.makeConfiguredEngine()
            self.lock.lock()
            self.engine = replacement
            self.lastTapAt = ProcessInfo.processInfo.systemUptime
            self.lock.unlock()

            self.registerObservers(for: replacement)
            try self.beginCapture(on: replacement)
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
        // Both together, so a summary cannot pair one run's frame count with
        // another run's sample rate.
        let (frames, sampleRate) = counters.snapshot()
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

        // Outside the lock, because both calls block until in-flight tap
        // callbacks return and those callbacks take the lock; and on
        // ``engineQueue``, because a configuration-change recovery may be
        // holding the graph right now. Awaited rather than fired and forgotten:
        // the engine has genuinely stopped by the time a summary is returned.
        await tearDownOnEngineQueue {
            if hadTap { engineToStop?.inputNode.removeTap(onBus: 0) }
            if engineToStop?.isRunning == true { engineToStop?.stop() }
        }

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

    // MARK: - Engine queue

    /// Runs `body` on ``engineQueue`` and suspends — rather than blocks — until
    /// it has finished, propagating whatever it throws.
    private func onEngineQueue<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            engineQueue.async {
                continuation.resume(with: Result(catching: body))
            }
        }
    }

    /// ``onEngineQueue(_:)`` for teardown, which has nothing to throw.
    private func tearDownOnEngineQueue(_ body: @escaping () -> Void) async {
        await withCheckedContinuation { continuation in
            engineQueue.async {
                body()
                continuation.resume()
            }
        }
    }

    /// Records that a recovery is being attempted and answers whether there is
    /// still budget for it — see ``maxConsecutiveRecoveries``.
    private func claimRecoveryBudget() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        if now - recoveryRunStarted > Self.recoveryRunWindow {
            recoveryRunStarted = now
            recoveryCount = 0
        }
        recoveryCount += 1
        return recoveryCount <= Self.maxConsecutiveRecoveries
    }

    // MARK: - Capture

    /// Installs the capture tap, reading the format it must be installed with
    /// at the moment it installs it.
    ///
    /// The format is ``usableInputFormat(of:)`` — the hardware's — and giving
    /// `installTap` anything else is what broke recording on some machines and
    /// not others. `outputFormat(forBus: 0)` looks like the obvious answer and
    /// is a lie: see ``usableInputFormat(of:)`` for why it goes stale the
    /// moment a device is selected and never recovers. Passing it produces a
    /// tap that is created without complaint and then delivers **zero
    /// buffers** — and, from a rebuild, an `NSException` that Swift cannot
    /// catch and that terminates the process:
    ///
    /// ```
    /// Failed to create tap due to format mismatch, <AVAudioFormat 1 ch, 44100 Hz>
    /// libc++abi: terminating due to uncaught exception
    /// ```
    ///
    /// That exception is worth reading closely, because it is AVFAudio saying
    /// which of the two formats it believes: it rejected the *cached* 44.1 kHz
    /// while the hardware — and `inputFormat` — said 48 kHz. The hardware
    /// format is the one the bus is validated against, so it is the one to
    /// install with.
    ///
    /// A bus with no usable format has nothing to tap, which is
    /// `noInputDevice` — an error the caller can present, not a crash.
    ///
    /// - Important: callers must be on ``engineQueue``.
    private func installTap(on input: AVAudioInputNode) throws {
        guard let tapFormat = Self.usableInputFormat(of: input) else {
            throw RecordingError.noInputDevice
        }

        input.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: tapFormat) { [weak self] buffer, _ in
            self?.handleTap(buffer)
        }
        lock.lock()
        tapInstalled = true
        lock.unlock()
    }

    /// A brand-new engine pointed at the configured input device.
    ///
    /// Always new, never reused. `AVAudioEngine` caches the input node's format
    /// and does not reliably refresh it across a stop or a device re-select —
    /// see ``recoverIfCaptureStalled()`` for what that costs — so an engine that
    /// has been reconfigured is thrown away rather than talked round.
    ///
    /// - Important: callers must be on ``engineQueue``.
    private func makeConfiguredEngine() throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        #if os(macOS)
        if let inputDeviceUID {
            // Must precede reading the input format: the format follows the
            // selected device. Throws `inputDeviceNotFound` when the chosen
            // device really has gone away, which is the one case that should
            // surface to the user.
            try AudioDeviceManager.setInputDevice(uid: inputDeviceUID, on: engine)
        }
        #endif
        return engine
    }

    /// Installs the tap and starts the engine.
    ///
    /// - Important: callers must be on ``engineQueue``.
    private func beginCapture(on engine: AVAudioEngine) throws {
        try installTap(on: engine.inputNode)
        try startEngine(engine)
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

        let now = ProcessInfo.processInfo.systemUptime

        lock.lock()
        // Stamped before the state guard, and stamped even while paused: this is
        // "a buffer arrived", not "a buffer was written". It is what
        // ``recoverIfCaptureStalled()`` reads to decide whether a configuration
        // change actually took the tap away.
        lastTapAt = now

        let currentState = state
        guard currentState == .recording || currentState == .paused else {
            lock.unlock()
            return
        }

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
                    // Nested inside `lock` on purpose. Exactness needs it:
                    // `stop()` snapshots the counters while holding `lock`, so
                    // updating them here means a buffer that made it to disk is
                    // always in the summary. Nesting is safe because the order
                    // is only ever lock → counters, never the reverse —
                    // `recordedDuration` takes the counter lock alone. And it
                    // costs a reader nothing: the counter lock is held for one
                    // addition, not for the write above it.
                    counters.add(frames: Int64(converted.frameLength))
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

    /// The format the input hardware is actually running at, or `nil` when
    /// there is nothing to record from.
    ///
    /// ## Why `inputFormat` is asked first, and why that is the whole bug
    ///
    /// This used to read `outputFormat(forBus: 0)` first and fall back to
    /// `inputFormat`. That is backwards, and it is the defect that made
    /// recording fail on some machines and not others.
    ///
    /// `AVAudioEngine` caches the input node's output format at the moment the
    /// node is first materialized — which
    /// ``AudioDeviceManager/setInputDevice(uid:on:)`` does itself, by reaching
    /// for `inputNode.audioUnit`, *before* it changes
    /// `kAudioOutputUnitProperty_CurrentDevice`. Selecting a device therefore
    /// leaves `outputFormat` describing the device that was there a moment ago,
    /// and it never corrects itself: measured on a machine whose node cached
    /// 44.1 kHz and whose selected microphone runs at 48 kHz, `outputFormat`
    /// still read 44100 three seconds and one configuration change later.
    ///
    /// Installing a tap with that stale format is not an approximation, it is a
    /// dead recording — the engine starts, reports itself running, and delivers
    /// **zero buffers**, forever. Which is exactly the shape of the report: the
    /// app records nothing on the machines where the chosen microphone's rate
    /// differs from whatever the node cached, and works perfectly everywhere the
    /// two happen to agree. Nothing about the machine matters except that
    /// coincidence.
    ///
    /// `inputFormat(forBus: 0)` reports the hardware and, as a side effect,
    /// brings `outputFormat` back into line with it — so asking in this order
    /// both gets the right answer and repairs the wrong one.
    private static func usableInputFormat(of node: AVAudioInputNode) -> AVAudioFormat? {
        let input = node.inputFormat(forBus: 0)
        if input.sampleRate > 0, input.channelCount > 0 { return input }
        // A disconnected or not-yet-configured device reports 0 Hz / 0 channels,
        // which is the signal that there is nothing to record from.
        let output = node.outputFormat(forBus: 0)
        if output.sampleRate > 0, output.channelCount > 0 { return output }
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

    /// The engine reconfigured itself — bring-up settling, or the input device
    /// was unplugged, switched, or changed sample rate.
    ///
    /// The two are indistinguishable from the notification alone, and guessing
    /// wrong either way breaks a recording — so this does not guess. It waits a
    /// beat and then asks capture itself, in ``recoverIfCaptureStalled()``.
    private func handleConfigurationChange() {
        // Never inline. `AVAudioEngineConfigurationChange` is delivered
        // synchronously on whichever thread posted it — one of CoreAudio's own,
        // and sometimes the very thread that is still inside `engine.start()` —
        // and Apple explicitly forbids reconfiguring or stopping the engine from
        // within the notification. `removeTap` and `stop()` additionally block
        // until in-flight tap callbacks return, so doing them here parks a
        // CoreAudio thread inside a CoreAudio callback.
        //
        // Hopping to ``engineQueue`` returns the posting thread immediately and
        // orders the response behind whatever start, resume or stop provoked it.
        engineQueue.asyncAfter(deadline: .now() + Self.configurationSettleDelay) { [weak self] in
            self?.recoverIfCaptureStalled()
        }
    }

    /// Rebuilds capture if — and only if — the configuration change actually
    /// stopped it.
    ///
    /// ## Why this is not simply "pause and tell the user"
    ///
    /// That was the old behaviour, and it read routine bring-up as device loss.
    /// Pointing the input node at a device — exactly what
    /// ``AudioDeviceManager/setInputDevice(uid:on:)`` does to
    /// `kAudioOutputUnitProperty_CurrentDevice` — makes CoreAudio post this
    /// notification a moment either side of `engine.start()` returning, **every
    /// time**. Measured, not guessed: recording from `BuiltInMicrophoneDevice`
    /// while it was already the system default still produced it. So every
    /// recording made with a *chosen* input device rather than the system
    /// default auto-paused within a second of starting and captured zero
    /// frames, and pressing Resume restarted the engine and provoked it again.
    /// That is the failure people hit on their machine and nowhere else: the
    /// trigger is not the hardware, it is whether the input picker has ever
    /// been touched.
    ///
    /// ## Why it is not simply "always rebuild" either
    ///
    /// Because a rebuild restarts the engine, and a restart posts the
    /// notification, which would rebuild again — forever. And because the
    /// notification really does sometimes arrive with the tap alive and well,
    /// where a rebuild is a needless gap in the audio.
    ///
    /// ## What it does instead
    ///
    /// Asks capture whether it is still running. ``lastTapAt`` is stamped by
    /// every tap callback, so after a settling delay the answer is a fact rather
    /// than an inference: buffers still arriving means the graph survived and
    /// there is nothing to do; silence means it did not, whatever the cause, and
    /// capture is rebuilt. Self-limiting by construction — a rebuild that works
    /// makes the next notification a no-op.
    ///
    /// The rebuild is onto a **fresh** `AVAudioEngine`. A reconfigured one keeps
    /// reporting its old input format: after `engine.stop()` and a re-select of
    /// the same device, `outputFormat(forBus: 0)` still read the previous
    /// device's 44.1 kHz, and installing a tap with a format the bus disagrees
    /// with raises an `NSException` — which Swift cannot catch and which
    /// terminates the app.
    ///
    /// - Important: runs on ``engineQueue``, and must, because it takes the
    ///   graph apart and puts a new one in its place.
    private func recoverIfCaptureStalled() {
        let now = ProcessInfo.processInfo.systemUptime

        lock.lock()
        guard state == .recording || state == .paused else {
            lock.unlock()
            return
        }
        // Buffers are still arriving: the notification was the engine talking
        // about itself, not the device going away.
        guard now - lastTapAt > Self.tapStaleThreshold else {
            lock.unlock()
            return
        }
        let oldEngine = engine
        let hadTap = tapInstalled
        tapInstalled = false
        // The hardware format may have changed; force a rebuild of both.
        converter = nil
        converterInputFormat = nil
        downmixFormat = nil
        downmixSourceFormat = nil
        lock.unlock()

        // The old engine's notifications are of no further interest, and its
        // token is about to be replaced.
        removeObservers()
        if hadTap { oldEngine?.inputNode.removeTap(onBus: 0) }
        if oldEngine?.isRunning == true { oldEngine?.stop() }

        do {
            guard claimRecoveryBudget() else {
                throw RecordingError.inputDeviceDisconnected
            }
            let engine = try makeConfiguredEngine()

            lock.lock()
            // Re-check: a `stop()` may have been queued behind this block's
            // teardown and taken ownership in the meantime.
            guard state == .recording || state == .paused else {
                lock.unlock()
                return
            }
            self.engine = engine
            // Stamped so the notification this rebuild is about to provoke does
            // not find a tap that has not had time to deliver anything yet.
            lastTapAt = ProcessInfo.processInfo.systemUptime
            lock.unlock()

            registerObservers(for: engine)
            try beginCapture(on: engine)
        } catch {
            // Nothing to capture from, or the graph will not settle. Pause
            // rather than tear down: everything already written is a valid file,
            // and `resume()` rebuilds against whatever is connected by then.
            lock.lock()
            let wasRecording = state == .recording
            if wasRecording { state = .paused }
            lock.unlock()

            if wasRecording { emit(.paused(.deviceLost)) }
            emit(.failed(.inputDeviceDisconnected))
        }
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
