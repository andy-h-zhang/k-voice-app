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
    /// `AVAudioSession`. Set at init and changed mid-recording by
    /// ``switchInput(to:)``.
    public var inputDeviceUID: String? {
        lock.lock()
        defer { lock.unlock() }
        return preferredDeviceUID
    }

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

    /// How long to let a configuration change settle before checking whether
    /// capture survived it. The watchdog would notice anyway; this just makes
    /// the response to a device switch quicker than one watchdog period.
    private static let configurationSettleDelay: TimeInterval = 0.3

    /// How often the watchdog asks whether capture is still alive.
    private static let watchdogInterval: TimeInterval = 0.5

    /// How quiet an engine that *has* delivered audio must be to count as dead.
    ///
    /// Generous on purpose. A 4096-frame tap buffer is ~85 ms at 48 kHz but
    /// ~256 ms at the 16 kHz a Bluetooth headset mic runs at, and a live tap
    /// judged dead gets torn down — which is how a working recording breaks.
    private static let tapStaleThreshold: TimeInterval = 1.0

    /// How long a freshly started engine gets to deliver its first buffer
    /// before it is judged dead.
    ///
    /// The built-in mic answers in ~100 ms. A Bluetooth headset switching from
    /// its playback profile to its call profile (AirPods connecting mid-meeting
    /// and becoming the default input) can take a few seconds, and rebuilding
    /// during that time restarts the switch, so it never finishes.
    private static let startupGrace: TimeInterval = 4.0

    /// Longest wait between rebuild attempts while capture is down. Attempts
    /// back off from 0.5 s up to this.
    private static let maxRebuildBackoff: TimeInterval = 2.0

    /// How long capture may stay down, while some input device still exists,
    /// before the recording is paused and the user told. Rebuilds continue
    /// after the pause, and the recording resumes on its own once audio flows.
    private static let outagePauseAfter: TimeInterval = 8.0

    /// The same, when no input device is connected at all. Short, but not zero:
    /// unplugging the default device can leave the system briefly without one
    /// before it picks the next.
    private static let noDevicePauseAfter: TimeInterval = 1.5

    // MARK: - Streams

    public let levelStream: AsyncStream<Float>
    public let events: AsyncStream<RecordingEvent>

    private let levelContinuation: AsyncStream<Float>.Continuation
    private let eventContinuation: AsyncStream<RecordingEvent>.Continuation

    // MARK: - Guarded state

    private let lock = UnfairLock()
    private var state: RecordingState = .idle
    /// Backing for ``inputDeviceUID``.
    private var preferredDeviceUID: String?
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

    /// Whether the current engine has delivered any buffer yet, and when it was
    /// started. Together they let ``checkCapture()`` tell "still starting up"
    /// apart from "dead" — see ``startupGrace``.
    private var hasDelivered = false
    private var captureStartedAt: TimeInterval = 0

    /// When the current outage began (`nil` while capture is healthy), when
    /// the next rebuild may be tried, and how many have been tried so far in
    /// this outage — the backoff.
    private var outageStartedAt: TimeInterval?
    private var nextRebuildAt: TimeInterval = 0
    private var rebuildAttempts = 0

    /// Set when the recording was paused because there was no audio to
    /// capture rather than by the user, so it can resume by itself once there
    /// is.
    private var pausedForDevice = false

    /// Periodically runs ``checkCapture()`` on ``engineQueue`` while a file is
    /// open.
    private var watchdog: DispatchSourceTimer?

    #if os(macOS)
    /// UID of the device actually being captured, and whether that is the
    /// system default standing in for a chosen device that went away. Compared
    /// after each rebuild to decide whether to emit
    /// ``RecordingEvent/inputDeviceChanged(name:isFallback:)``.
    private var currentDeviceUID: String?
    private var usingFallback = false
    #endif

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
        self.preferredDeviceUID = inputDeviceUID
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
        watchdog?.cancel()
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
            // No fallback at start: a chosen device that is missing before the
            // recording begins is an error the user can see and fix, not a
            // reason to quietly record from a different microphone.
            let engine = try self.makeConfiguredEngine(allowFallback: false).engine
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
        self.hasDelivered = false
        self.captureStartedAt = ProcessInfo.processInfo.systemUptime
        self.outageStartedAt = nil
        self.nextRebuildAt = 0
        self.rebuildAttempts = 0
        self.pausedForDevice = false
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

        lock.lock()
        captureStartedAt = ProcessInfo.processInfo.systemUptime
        lock.unlock()

        startWatchdog()
        #if os(macOS)
        // Not awaited: naming the device walks the CoreAudio HAL, which is slow
        // mid-bring-up, and nothing about starting depends on the answer.
        engineQueue.async { [weak self] in self?.noteCurrentDevice(fellBack: false, announce: false) }
        #endif

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
        lock.unlock()

        // On the engine queue, ordered behind any recovery still in flight, and
        // judging the engine's health there rather than here so the answer
        // cannot be stale by the time it is used.
        try await onEngineQueue {
            // A plain `pause()` left a live engine running; rebuilding it would
            // only open a gap. Anything else — capture lost to a device change,
            // or an engine that never came back — is rebuilt against whatever
            // is connected now.
            if !self.captureIsAlive(at: ProcessInfo.processInfo.systemUptime) {
                try self.rebuildCapture()
            }
        }

        lock.lock()
        let resumed = state == .paused
        if resumed {
            state = .recording
            pausedForDevice = false
        }
        lock.unlock()
        if resumed { emit(.resumed) }
    }

    /// Moves capture to a different input device without ending the
    /// recording: the audio keeps going into the same file, with a short gap
    /// while the new device starts up.
    ///
    /// - Parameter uid: The device to record from, or `nil` for the system
    ///   default.
    /// - Throws: ``RecordingError/inputDeviceNotFound(uid:)`` if the device is
    ///   not connected — checked *before* anything is torn down, so the
    ///   recording carries on undisturbed on the device it was using. Other
    ///   errors mean the new device would not start; the watchdog keeps
    ///   retrying, as after any device change.
    ///
    /// Before `start()` this only changes which device `start()` will use;
    /// after `stop()` it does nothing.
    public func switchInput(to uid: String?) async throws {
        try await onEngineQueue {
            self.lock.lock()
            let active = self.state == .recording || self.state == .paused
            let unchanged = uid == self.preferredDeviceUID
            if !active, self.state == .idle { self.preferredDeviceUID = uid }
            self.lock.unlock()
            guard active, !unchanged else { return }

            #if os(macOS)
            if let uid {
                _ = try AudioDeviceManager.inputDevice(withUID: uid)
            }
            #endif

            self.lock.lock()
            self.preferredDeviceUID = uid
            // A deliberate switch starts with a clean slate: no outage carried
            // over from before, no backoff delaying the first retry.
            self.outageStartedAt = nil
            self.nextRebuildAt = 0
            self.rebuildAttempts = 0
            self.lock.unlock()

            try self.rebuildCapture()
        }
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
        let watchdogToCancel = watchdog
        watchdog = nil
        lock.unlock()

        watchdogToCancel?.cancel()
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
    /// see ``rebuildCapture()`` for what that costs — so an engine that has been
    /// reconfigured is thrown away rather than talked round.
    ///
    /// - Parameter allowFallback: When the chosen device is no longer
    ///   connected, return an engine on the system default instead of throwing
    ///   `inputDeviceNotFound`. Mid-recording, a microphone that disappears
    ///   should not end the meeting's audio.
    /// - Returns: The engine, and whether it is the fallback.
    /// - Important: callers must be on ``engineQueue``.
    private func makeConfiguredEngine(allowFallback: Bool) throws -> (engine: AVAudioEngine, fellBack: Bool) {
        #if os(macOS)
        if let inputDeviceUID {
            let engine = AVAudioEngine()
            do {
                // Must precede reading the input format: the format follows the
                // selected device.
                try AudioDeviceManager.setInputDevice(uid: inputDeviceUID, on: engine)
                return (engine, false)
            } catch RecordingError.inputDeviceNotFound where allowFallback {
                // A fresh engine rather than the one above, which may already
                // have materialized its input node: an untouched engine follows
                // the system default.
                return (AVAudioEngine(), true)
            }
        }
        #endif
        return (AVAudioEngine(), false)
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
        // ``checkCapture()`` reads to decide whether capture is still alive.
        lastTapAt = now
        hasDelivered = true

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
    /// beat and then asks capture itself, in ``checkCapture()``.
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
            self?.checkCapture()
        }
    }

    // MARK: - Keeping capture alive

    /// Starts the timer that runs ``checkCapture()`` for as long as a file is
    /// open.
    ///
    /// A configuration-change notification is the usual sign that the device
    /// changed, but it is not the only one, and a single check made 0.3 s after
    /// it cannot follow a recovery that takes longer than that — a Bluetooth
    /// headset coming up, or a rebuild that fails once and works on the next
    /// try. The watchdog is what keeps trying.
    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: engineQueue)
        timer.schedule(
            deadline: .now() + Self.watchdogInterval,
            repeating: Self.watchdogInterval,
            leeway: .milliseconds(100)
        )
        timer.setEventHandler { [weak self] in self?.checkCapture() }

        lock.lock()
        let previous = watchdog
        watchdog = timer
        lock.unlock()

        previous?.cancel()
        timer.resume()
    }

    /// Whether the current engine is delivering audio, or is new enough that
    /// it may still be about to.
    ///
    /// - Important: takes `lock`, so callers must not hold it.
    private func captureIsAlive(at now: TimeInterval) -> Bool {
        let running = currentEngineIsRunning()
        lock.lock()
        defer { lock.unlock() }
        return captureIsAliveLocked(at: now, engineRunning: running)
    }

    /// Whether the current engine is running, asked *outside* `lock`: the tap
    /// callback takes `lock`, so calling into the engine while holding it is
    /// asking for a lock-order inversion.
    ///
    /// - Important: callers must be on ``engineQueue`` — the only place the
    ///   engine is replaced — so the answer still describes the current engine
    ///   when the caller next takes `lock`.
    private func currentEngineIsRunning() -> Bool {
        lock.lock()
        let current = engine
        lock.unlock()
        return current?.isRunning ?? false
    }

    /// ``captureIsAlive(at:)`` for callers already holding `lock`.
    ///
    /// `engineRunning` matters because an engine that a configuration change
    /// stopped is dead now, not after ``tapStaleThreshold`` of silence:
    /// `AVAudioEngine` stops itself when the device under it changes, so this
    /// is what keeps the gap in the audio short.
    private func captureIsAliveLocked(at now: TimeInterval, engineRunning: Bool) -> Bool {
        guard engine != nil, engineRunning, tapInstalled else { return false }
        if hasDelivered { return now - lastTapAt <= Self.tapStaleThreshold }
        return now - captureStartedAt <= Self.startupGrace
    }

    /// Keeps capture running across device changes: does nothing while audio
    /// is arriving, rebuilds capture when it is not, and pauses the recording
    /// only when the outage has gone on too long to hide.
    ///
    /// ## Why not "pause and tell the user" on the first sign of trouble
    ///
    /// Because the first sign of trouble is routine. Pointing the input node at
    /// a device posts a configuration change a moment either side of
    /// `engine.start()` returning, **every time** — measured, not guessed. And a
    /// real device switch is messy: the new default may report zero channels
    /// for a moment, `engine.start()` may fail while it settles, and a Bluetooth
    /// headset may take seconds to deliver its first buffer. Each of those used
    /// to end in a pause. Now each is just another attempt.
    ///
    /// ## Why not "always rebuild" either
    ///
    /// A rebuild restarts the engine, a restart posts the notification, and the
    /// notification would rebuild again — forever. And it sometimes arrives
    /// with the tap alive and well, where a rebuild is a needless gap. So the
    /// question asked is a fact, not an inference: has this engine delivered
    /// audio recently (``tapStaleThreshold``), or is it young enough that it may
    /// still be about to (``startupGrace``)? Only "no" leads to a rebuild, and
    /// rebuilds back off (``maxRebuildBackoff``).
    ///
    /// ## When it does pause
    ///
    /// When capture has been down for ``outagePauseAfter`` — or for
    /// ``noDevicePauseAfter`` when there is no input device at all. The file is
    /// intact, rebuilding carries on in the background, and the first buffer
    /// that arrives resumes the recording by itself.
    ///
    /// - Important: runs on ``engineQueue``, and must, because it may take the
    ///   graph apart and put a new one in its place.
    private func checkCapture() {
        let now = ProcessInfo.processInfo.systemUptime
        let engineRunning = currentEngineIsRunning()

        lock.lock()
        guard state == .recording || state == .paused else {
            lock.unlock()
            return
        }

        if captureIsAliveLocked(at: now, engineRunning: engineRunning) {
            // Still inside the start-up grace counts as alive — leave it alone —
            // but only a delivered buffer ends the outage.
            guard hasDelivered else {
                lock.unlock()
                return
            }
            outageStartedAt = nil
            rebuildAttempts = 0
            nextRebuildAt = 0
            let autoResume = pausedForDevice && state == .paused
            if autoResume {
                state = .recording
                pausedForDevice = false
            }
            lock.unlock()
            if autoResume { emit(.resumed) }
            return
        }

        let outageStart = outageStartedAt ?? now
        outageStartedAt = outageStart
        let rebuildDue = now >= nextRebuildAt
        if rebuildDue {
            rebuildAttempts += 1
            let backoff = 0.5 * pow(2, Double(min(rebuildAttempts - 1, 4)))
            nextRebuildAt = now + min(backoff, Self.maxRebuildBackoff)
        }
        lock.unlock()

        var rebuildFailed = false
        if rebuildDue {
            do {
                try rebuildCapture()
            } catch {
                rebuildFailed = true
            }
        }

        let outage = now - outageStart
        let shouldPause = outage >= Self.outagePauseAfter
            || (rebuildFailed && outage >= Self.noDevicePauseAfter && !Self.anyInputDeviceConnected())
        if shouldPause { pauseForMissingInput() }
    }

    /// Replaces the engine with a new one on the chosen device — or, if that
    /// device has gone, on the system default — and starts capturing from it.
    ///
    /// The replacement is a **fresh** `AVAudioEngine`. A reconfigured one keeps
    /// reporting its old input format: after `engine.stop()` and a re-select of
    /// the same device, `outputFormat(forBus: 0)` still read the previous
    /// device's 44.1 kHz, and installing a tap with a format the bus disagrees
    /// with raises an `NSException` — which Swift cannot catch and which
    /// terminates the app.
    ///
    /// On failure the old engine is already gone and no new one is left
    /// behind; the next ``checkCapture()`` tries again.
    ///
    /// - Important: callers must be on ``engineQueue``.
    private func rebuildCapture() throws {
        tearDownEngine()

        lock.lock()
        // The hardware format may have changed; force a rebuild of both.
        converter = nil
        converterInputFormat = nil
        downmixFormat = nil
        downmixSourceFormat = nil
        lock.unlock()

        let (engine, fellBack) = try makeConfiguredEngine(allowFallback: true)

        lock.lock()
        // A `stop()` may have taken ownership while this was queued.
        guard state == .recording || state == .paused else {
            lock.unlock()
            return
        }
        self.engine = engine
        hasDelivered = false
        captureStartedAt = ProcessInfo.processInfo.systemUptime
        lock.unlock()

        registerObservers(for: engine)
        do {
            try beginCapture(on: engine)
        } catch {
            tearDownEngine()
            throw error
        }

        lock.lock()
        // From when the engine is actually running: `start()` can block for a
        // while, and that time is not the device's to account for.
        captureStartedAt = ProcessInfo.processInfo.systemUptime
        let stillActive = state == .recording || state == .paused
        lock.unlock()

        // `stop()` ran while this engine was starting and saw no tap to remove.
        guard stillActive else {
            if engine.isRunning { engine.stop() }
            return
        }

        #if os(macOS)
        noteCurrentDevice(fellBack: fellBack, announce: true)
        #endif
    }

    /// Detaches and stops the current engine, if there is one.
    ///
    /// - Important: callers must be on ``engineQueue``.
    private func tearDownEngine() {
        lock.lock()
        let oldEngine = engine
        let hadTap = tapInstalled
        engine = nil
        tapInstalled = false
        lock.unlock()

        // The old engine's notifications are of no further interest.
        removeObservers()
        if hadTap { oldEngine?.inputNode.removeTap(onBus: 0) }
        if oldEngine?.isRunning == true { oldEngine?.stop() }
    }

    /// Pauses a recording that has had no audio for too long, marking the
    /// pause as one the source may end by itself.
    private func pauseForMissingInput() {
        lock.lock()
        let wasRecording = state == .recording
        if wasRecording {
            state = .paused
            pausedForDevice = true
        }
        lock.unlock()

        if wasRecording {
            emit(.paused(.deviceLost))
            emit(.failed(.inputDeviceDisconnected))
        }
    }

    /// Whether any input device is connected at all — the difference between
    /// "the switch is taking a while" and "there is nothing to switch to".
    private static func anyInputDeviceConnected() -> Bool {
        #if os(macOS)
        // An unreadable list is not evidence of an empty one.
        guard let devices = try? AudioDeviceManager.inputDevices() else { return true }
        return !devices.isEmpty
        #else
        return true
        #endif
    }

    #if os(macOS)
    /// Records which device is being captured now and, when `announce` is set
    /// and it differs from before, says so through ``events``.
    ///
    /// - Important: callers must be on ``engineQueue`` — this walks the HAL.
    private func noteCurrentDevice(fellBack: Bool, announce: Bool) {
        let device: AudioInputDevice?
        if let inputDeviceUID, !fellBack {
            device = try? AudioDeviceManager.inputDevice(withUID: inputDeviceUID)
        } else {
            device = try? AudioDeviceManager.defaultInputDevice()
        }

        lock.lock()
        let changed = device?.uid != currentDeviceUID || fellBack != usingFallback
        currentDeviceUID = device?.uid
        usingFallback = fellBack
        let active = state == .recording || state == .paused
        lock.unlock()

        if announce, changed, active {
            emit(.inputDeviceChanged(name: device?.name, isFallback: fellBack))
        }
    }
    #endif

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
