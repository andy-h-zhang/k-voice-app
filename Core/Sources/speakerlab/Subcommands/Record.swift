import ArgumentParser
import Dispatch
import Foundation
import KVoiceCore

#if canImport(Darwin)
import Darwin
#endif

/// `speakerlab record` — thin CLI wrapper around the recording engine, used
/// to produce test audio for the pipeline above.
struct Record: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Record audio to a .m4a file using the recording engine.",
        discussion: """
        Records 48 kHz mono AAC, streaming to disk as it captures, into

            <out>/<title>/<title>.m4a

        Controls while recording: space pauses and resumes, q stops.
        Ctrl-C also stops cleanly — the file is finalized either way, and
        whatever was captured before an interruption stays playable.

        Examples:
          speakerlab record --list-devices
          speakerlab record --out ~/Documents/KVoice --title "Standup"
          speakerlab record -o /tmp/rec -d BuiltInMicrophoneDevice --max-seconds 30
        """
    )

    @Flag(name: .long, help: "List available audio input devices and exit.")
    var listDevices = false

    @Option(
        name: [.customShort("o"), .long],
        help: ArgumentHelp("Library folder to create the recording folder in.", valueName: "dir")
    )
    var out: String?

    @Option(
        name: [.customShort("d"), .long],
        help: ArgumentHelp("UID of the input device to record from (see --list-devices).", valueName: "uid")
    )
    var device: String?

    @Option(
        name: [.customShort("t"), .long],
        help: ArgumentHelp("Recording title; becomes the folder and file name.", valueName: "title")
    )
    var title: String?

    @Option(
        name: .long,
        help: ArgumentHelp("Stop automatically after this many seconds of audio.", valueName: "seconds")
    )
    var maxSeconds: Double?

    func run() throws {
        // Piped stdout is block-buffered by default, which swallows progress
        // output until the process exits.
        setvbuf(stdout, nil, _IOLBF, 0)

        if listDevices {
            try Self.printInputDevices()
            return
        }

        guard let out else {
            throw ValidationError("Missing expected option '--out <dir>'. Pass --list-devices to list input devices instead.")
        }
        if let maxSeconds, maxSeconds <= 0 {
            throw ValidationError("--max-seconds must be greater than zero.")
        }

        let rootURL = URL(fileURLWithPath: (out as NSString).expandingTildeInPath).standardizedFileURL
        let session = RecordingSession(
            rootURL: rootURL,
            title: title,
            deviceUID: device,
            maxSeconds: maxSeconds
        )

        // The root command is a synchronous `ParsableCommand` (and is owned
        // by another phase), so async subcommands are not dispatched for us:
        // bridge here instead of changing the CLI's entry point.
        do {
            try Blocking.run { try await session.run() }
        } catch let error as RecordingError {
            FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
            throw ExitCode.failure
        } catch let error as StorageError {
            FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
            throw ExitCode.failure
        }
    }

    // MARK: - Device listing

    private static func printInputDevices() throws {
        #if os(macOS)
        let devices = try AudioDeviceManager.inputDevices()
        guard !devices.isEmpty else {
            print("No audio input devices found.")
            return
        }

        let uidWidth = max(3, devices.map(\.uid.count).max() ?? 3)
        let nameWidth = max(4, devices.map(\.name.count).max() ?? 4)

        print("\("UID".padded(to: uidWidth))  \("NAME".padded(to: nameWidth))  CH  RATE")
        for inputDevice in devices {
            let rate = inputDevice.nominalSampleRate > 0
                ? String(Int(inputDevice.nominalSampleRate))
                : "-"
            var line = inputDevice.uid.padded(to: uidWidth)
            line += "  " + inputDevice.name.padded(to: nameWidth)
            line += "  " + String(inputDevice.inputChannelCount).padded(to: 2)
            line += "  " + rate
            if inputDevice.isDefault { line += "  (default)" }
            print(line)
        }
        print("\nRecord from one with: speakerlab record --out <dir> --device <UID>")
        #else
        print("Input device enumeration is available on macOS only.")
        #endif
    }
}

// MARK: - Session

/// Owns one `record` invocation: creates the folder, drives ``MicSource``,
/// renders the meter, and finalizes.
private final class RecordingSession: @unchecked Sendable {
    private let rootURL: URL
    private let title: String?
    private let deviceUID: String?
    private let maxSeconds: Double?

    private let controls = ControlFlags()
    private let console: Console

    init(rootURL: URL, title: String?, deviceUID: String?, maxSeconds: Double?) {
        self.rootURL = rootURL
        self.title = title
        self.deviceUID = deviceUID
        self.maxSeconds = maxSeconds
        self.console = Console(interactive: Console.isInteractiveTerminal)
    }

    func run() async throws {
        let store = RecordingStore(rootURL: rootURL)
        let folder = try store.createRecording(title: title ?? Self.defaultTitle())

        print("Library:  \(store.rootURL.path)")
        print("Writing:  \(folder.audioURL.path)")
        if let deviceUID { print("Device:   \(deviceUID)") }
        print("")

        // A CLI should fail fast with instructions rather than sit on a
        // permission prompt nobody is going to see.
        let source = MicSource(inputDeviceUID: deviceUID, permissionRequestTimeout: 10)
        let signals = SignalWatcher(controls: controls)
        let keys = KeyReader(controls: controls, interactive: console.interactive)

        signals.start()
        keys.start()
        defer {
            keys.stop()
            signals.stop()
        }

        do {
            try await source.start(writingTo: folder.audioURL, format: .aacMono48k)
        } catch {
            // Don't leave an empty folder behind for a recording that never
            // happened.
            removeIfEmpty(folder.folderURL)
            throw error
        }

        let levelTask = Task.detached { [console] in
            for await level in source.levelStream { console.setLevel(level) }
        }
        let eventTask = Task.detached { [console, controls, maxSeconds] in
            for await event in source.events {
                if let note = Self.describe(event) { console.note(note) }
                // --max-seconds marks an unattended run. Audio time stops
                // accumulating once capture fails, so waiting for the limit
                // would wait forever; stop and finalize what we have.
                if case .failed = event, maxSeconds != nil {
                    controls.requestStop()
                }
            }
        }

        if console.interactive {
            console.note("space = pause/resume, q = stop")
        } else {
            console.note("not a terminal: keypress controls disabled, send SIGINT to stop")
        }

        await drive(source)

        let summary = await source.stop()
        levelTask.cancel()
        eventTask.cancel()
        console.finish()

        try report(summary: summary, folder: folder, store: store)
    }

    /// The control loop: applies keypresses, redraws at ~10 Hz, and returns
    /// when a stop is requested or `--max-seconds` is reached.
    private func drive(_ source: MicSource) async {
        while !controls.stopRequested {
            if controls.takePauseToggle() {
                if source.recordingState == .paused {
                    do {
                        try await source.resume()
                    } catch {
                        console.note("could not resume: \(error.localizedDescription)")
                    }
                } else {
                    await source.pause()
                }
            }

            console.render(elapsed: source.recordedDuration, state: source.recordingState)

            if let maxSeconds, source.recordedDuration >= maxSeconds { break }

            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func report(summary: RecordingSummary?, folder: RecordingFolder, store: RecordingStore) throws {
        guard let summary else {
            print("Nothing was recorded.")
            removeIfEmpty(folder.folderURL)
            return
        }

        print("")
        print("Saved:    \(summary.url.path)")
        print("Recorded: \(Console.timestamp(summary.duration)) (\(String(format: "%.2f", summary.duration)) s)")
        print("Format:   \(Int(summary.sampleRate)) Hz, \(summary.channelCount) ch, \(summary.frameCount) frames")

        // Probe the finished file: proof that it was finalized and is
        // readable, not just that bytes were written.
        do {
            let probed = try RecordingStore.duration(ofAudioAt: summary.url)
            print("Probed:   \(Console.timestamp(probed)) (\(String(format: "%.2f", probed)) s from the file on disk)")
        } catch {
            print("Probed:   failed — \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }

    private func removeIfEmpty(_ url: URL) {
        let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path)
        if contents?.isEmpty ?? false {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func describe(_ event: RecordingEvent) -> String? {
        switch event {
        case .started:
            return "recording started"
        case .paused(.user):
            return "paused"
        case .paused(.deviceLost):
            return "paused: input device changed or disconnected"
        case .paused(.interrupted):
            return "paused: interrupted by the system"
        case .paused(.writeFailure):
            return "paused: writing to disk failed"
        case .resumed:
            return "resumed"
        case .stopped:
            return nil                                  // reported in full below
        case .failed(let error):
            return "error: \(error.localizedDescription)"
        }
    }

    private static func defaultTitle() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return "\(formatter.string(from: Date())) Recording"
    }
}

// MARK: - Console

/// Single-line elapsed-time + level meter, plus out-of-band notices.
///
/// Everything prints from here so the meter line and event messages cannot
/// interleave into garbage.
private final class Console: @unchecked Sendable {
    private struct State {
        var level: Float = 0
        var smoother = LevelSmoother()
        var notices: [String] = []
        var lastRender: Double = 0
        var meterVisible = false
        var lastStatusPrint: Double = 0
    }

    /// Meter width in cells.
    private static let barWidth = 24
    /// Redraw interval; the level stream arrives faster than this.
    private static let renderInterval: Double = 0.1
    /// Status-line interval when output is not a terminal.
    private static let statusInterval: Double = 5

    let interactive: Bool
    private let state = StateBox(State())

    init(interactive: Bool) {
        self.interactive = interactive
    }

    static var isInteractiveTerminal: Bool {
        #if canImport(Darwin)
        return isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
        #else
        return false
        #endif
    }

    func setLevel(_ level: Float) {
        state.mutate { $0.level = level }
    }

    func note(_ message: String) {
        state.mutate { $0.notices.append(message) }
    }

    func render(elapsed: TimeInterval, state recordingState: RecordingState) {
        let now = ProcessInfo.processInfo.systemUptime

        let (notices, level, shouldRender, shouldPrintStatus) = state.mutate {
            (state: inout State) -> ([String], Float, Bool, Bool) in
            let notices = state.notices
            state.notices = []

            let due = now - state.lastRender >= Self.renderInterval
            if due {
                state.lastRender = now
                state.smoother.update(state.level)
            }

            let statusDue = now - state.lastStatusPrint >= Self.statusInterval
            if statusDue { state.lastStatusPrint = now }

            return (notices, state.smoother.value, due, statusDue)
        }

        guard interactive else {
            for notice in notices { print(notice) }
            // No terminal: periodic status lines instead of a live meter, so
            // piping to a log file stays readable.
            if shouldPrintStatus {
                print("\(Self.label(for: recordingState)) \(Self.timestamp(elapsed))  level \(Int(level * 100))%")
            }
            return
        }

        if !notices.isEmpty {
            clearLine()
            for notice in notices { print(notice) }
        }

        guard shouldRender else { return }

        let filled = Int((level * Float(Self.barWidth)).rounded())
        let bar = String(repeating: "#", count: min(filled, Self.barWidth))
            + String(repeating: "-", count: max(0, Self.barWidth - filled))
        let decibels = AudioLevel.defaultFloorDB * (1 - level)
        let readout = level <= 0 ? "  -inf dB" : String(format: "%6.1f dB", decibels)

        clearLine()
        print("\(Self.label(for: recordingState)) \(Self.timestamp(elapsed))  [\(bar)] \(readout)", terminator: "")
        fflush(stdout)
        state.mutate { $0.meterVisible = true }
    }

    /// Ends the meter line so later output starts clean.
    func finish() {
        let notices = state.mutate { (state: inout State) -> [String] in
            let pending = state.notices
            state.notices = []
            return pending
        }
        if interactive { clearLine() }
        for notice in notices { print(notice) }
        fflush(stdout)
    }

    private func clearLine() {
        guard interactive else { return }
        // CR + "erase to end of line": overwrite in place rather than
        // scrolling a new line every 100 ms.
        print("\r\u{1B}[2K", terminator: "")
    }

    private static func label(for state: RecordingState) -> String {
        switch state {
        case .recording: return "REC  "
        case .paused: return "PAUSE"
        case .idle: return "IDLE "
        case .stopping, .stopped: return "STOP "
        }
    }

    /// `hh:mm:ss`.
    static func timestamp(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00:00" }
        let total = Int(seconds)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

// MARK: - Controls

/// Stop / pause requests raised from a signal handler or the key reader.
private final class ControlFlags: @unchecked Sendable {
    private let state = StateBox((stop: false, pauseToggles: 0))

    var stopRequested: Bool { state.mutate { $0.stop } }

    func requestStop() {
        state.mutate { $0.stop = true }
    }

    func togglePause() {
        state.mutate { $0.pauseToggles += 1 }
    }

    /// Consumes one queued pause/resume request.
    func takePauseToggle() -> Bool {
        state.mutate { value in
            guard value.pauseToggles > 0 else { return false }
            value.pauseToggles -= 1
            return true
        }
    }
}

/// SIGINT/SIGTERM → clean stop, so Ctrl-C finalizes the file instead of
/// killing the process mid-write.
private final class SignalWatcher: @unchecked Sendable {
    private let controls: ControlFlags
    private var sources: [DispatchSourceSignal] = []

    init(controls: ControlFlags) {
        self.controls = controls
    }

    func start() {
        for signalNumber in [SIGINT, SIGTERM] {
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler { [controls] in controls.requestStop() }
            // Ignore the default disposition so only the dispatch source
            // sees it; otherwise the process dies before finalizing.
            signal(signalNumber, SIG_IGN)
            source.resume()
            sources.append(source)
        }
    }

    func stop() {
        for source in sources { source.cancel() }
        sources = []
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)
    }
}

/// Reads single keypresses in raw mode: space toggles pause, q stops.
private final class KeyReader: @unchecked Sendable {
    private let controls: ControlFlags
    private let interactive: Bool
    private let running = StateBox(true)
    private var thread: Thread?

    #if canImport(Darwin)
    private var originalTerminal = termios()
    private var terminalModified = false
    #endif

    init(controls: ControlFlags, interactive: Bool) {
        self.controls = controls
        self.interactive = interactive
    }

    func start() {
        guard interactive else { return }
        #if canImport(Darwin)
        guard enterRawMode() else { return }

        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = "speakerlab.record.keys"
        thread.start()
        self.thread = thread
        #endif
    }

    func stop() {
        running.mutate { $0 = false }
        #if canImport(Darwin)
        restoreTerminal()
        #endif
    }

    #if canImport(Darwin)
    /// Turns off echo and line buffering, and makes `read` time out so the
    /// thread can notice `stop()`.
    private func enterRawMode() -> Bool {
        guard tcgetattr(STDIN_FILENO, &originalTerminal) == 0 else { return false }

        var raw = originalTerminal
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON)
        withUnsafeMutablePointer(to: &raw.c_cc) { pointer in
            pointer.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { controlCharacters in
                controlCharacters[Int(VMIN)] = 0    // don't block for a full byte
                controlCharacters[Int(VTIME)] = 1   // 0.1 s timeout
            }
        }

        guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else { return false }
        terminalModified = true
        return true
    }

    private func restoreTerminal() {
        guard terminalModified else { return }
        terminalModified = false
        tcsetattr(STDIN_FILENO, TCSANOW, &originalTerminal)
    }

    private func readLoop() {
        while running.mutate({ $0 }) {
            var byte: UInt8 = 0
            let count = read(STDIN_FILENO, &byte, 1)
            if count == 1 {
                switch byte {
                case UInt8(ascii: " "):
                    controls.togglePause()
                case UInt8(ascii: "q"), UInt8(ascii: "Q"):
                    controls.requestStop()
                default:
                    break
                }
            } else if count < 0 && errno != EINTR && errno != EAGAIN {
                break
            }
        }
    }
    #endif
}

// MARK: - Small utilities

/// Serial-queue-guarded box. Used instead of a lock because these are
/// touched from `async` contexts, where `NSLock.lock()` is unavailable.
private final class StateBox<Value>: @unchecked Sendable {
    private let queue = DispatchQueue(label: "speakerlab.record.state")
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    @discardableResult
    func mutate<Result>(_ body: (inout Value) -> Result) -> Result {
        queue.sync { body(&value) }
    }
}

/// Runs async work from a synchronous command and waits for it.
private enum Blocking {
    static func run<Value: Sendable>(_ body: @escaping @Sendable () async throws -> Value) throws -> Value {
        let semaphore = DispatchSemaphore(value: 0)
        let box = StateBox<Swift.Result<Value, Error>?>(nil)

        Task.detached(priority: .userInitiated) {
            do {
                let value = try await body()
                box.mutate { $0 = .success(value) }
            } catch {
                box.mutate { $0 = .failure(error) }
            }
            semaphore.signal()
        }

        semaphore.wait()
        guard let result = box.mutate({ $0 }) else {
            throw ExitCode.failure
        }
        return try result.get()
    }
}

extension String {
    /// Pads with spaces to `width` for column output.
    fileprivate func padded(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
