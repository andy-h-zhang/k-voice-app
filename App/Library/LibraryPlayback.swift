import AVFoundation
import Foundation
import Observation

/// Plays one recording at a time, straight from the library list.
///
/// ## Why this is not ``TranscriptPlayback``
///
/// They look alike — both wrap `AVAudioPlayer` and tick at 10 Hz — and they
/// answer different questions. `TranscriptPlayback` exists to keep a *highlight*
/// in step with the audio: it holds a table of utterance spans, resolves the
/// playhead against it, and is owned by one editor screen for one recording.
/// This one has no transcript, has to know *which row* is playing out of a list
/// of many, and must stop whatever was playing when another row is started.
/// Folding the two together would mean a span table that is empty half the time
/// and a "current recording" that the editor never changes.
///
/// ## One player, one row
///
/// A single `AVAudioPlayer` is reused for whichever row is playing. Starting a
/// second row stops the first: two recordings of the same meeting playing over
/// each other is never what a click meant, and it is the behaviour every media
/// library on this platform has.
@MainActor
@Observable
final class LibraryPlayback {

    /// The recording currently loaded, playing or paused. `nil` when nothing
    /// is loaded — which is how a row knows to draw "Play" rather than a
    /// transport.
    private(set) var recordingID: UUID?

    private(set) var isPlaying = false

    /// Playhead position in seconds. Moves at the tick rate while playing.
    private(set) var currentTime: TimeInterval = 0

    /// Length of the loaded audio, in seconds.
    private(set) var duration: TimeInterval = 0

    /// Set when the audio could not be opened — a file moved or deleted out
    /// from under the library.
    var errorMessage: String?

    /// True while the user drags the scrubber, so ticks stop fighting the drag.
    var isScrubbing = false {
        didSet {
            guard oldValue, !isScrubbing else { return }
            seek(to: currentTime)
        }
    }

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    /// 10 Hz: enough for a progress bar to look continuous, and the only thing
    /// reading `currentTime` is the one row that is playing.
    static let tickInterval = Duration.milliseconds(100)

    // MARK: - Transport

    /// The whole of what a row's play button does.
    ///
    /// Clicking the row that is already playing pauses it; clicking a different
    /// row switches to it and starts from the top.
    func toggle(id: UUID, url: URL) {
        if recordingID == id, player != nil {
            isPlaying ? pause() : play()
            return
        }
        load(id: id, url: url)
        play()
    }

    func play() {
        guard let player else { return }
        // Parked at the end: start over rather than play nothing. The published
        // position rewinds with it, so the scrubber does not sit at the end for
        // the first tenth of a second.
        if player.currentTime >= duration - 0.05 {
            player.currentTime = 0
            currentTime = 0
        }
        guard player.play() else { return }
        isPlaying = true
        startTicking()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        ticker?.cancel()
        ticker = nil
        if let player { currentTime = player.currentTime }
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        let clamped = min(max(0, time), max(0, duration))
        player.currentTime = clamped
        currentTime = clamped
    }

    /// Moves the *displayed* playhead without touching the player — what a
    /// scrubber drag does. Releasing it performs one real seek.
    func scrub(to time: TimeInterval) {
        currentTime = min(max(0, time), max(0, duration))
    }

    func skip(by delta: TimeInterval) {
        seek(to: currentTime + delta)
    }

    /// Releases the audio device and forgets the recording.
    func stop() {
        ticker?.cancel()
        ticker = nil
        player?.stop()
        player = nil
        recordingID = nil
        isPlaying = false
        isScrubbing = false
        currentTime = 0
        duration = 0
    }

    /// Stops if — and only if — this is the recording playing.
    ///
    /// Called when a row is renamed or trashed: the file underneath an open
    /// `AVAudioPlayer` has just moved, and the alternative to stopping is a
    /// transport that scrubs a file that is no longer there.
    func stopIfPlaying(id: UUID) {
        guard recordingID == id else { return }
        stop()
    }

    // MARK: - Loading

    private func load(id: UUID, url: URL) {
        stop()

        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = """
                The audio file for this recording is missing from \
                \(url.deletingLastPathComponent().path).
                """
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            self.player = player
            recordingID = id
            duration = player.duration
            currentTime = 0
        } catch {
            errorMessage = "Could not play this recording: \(error.localizedDescription)"
        }
    }

    // MARK: - Ticking

    private func startTicking() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickInterval)
                guard !Task.isCancelled, let self, self.isPlaying else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        guard let player else { return }

        if player.isPlaying {
            if !isScrubbing { currentTime = min(player.currentTime, duration) }
        } else {
            // Stopped without anyone asking: playback reached the end. Park the
            // playhead there rather than wherever the last tick read.
            currentTime = duration
            isPlaying = false
            ticker?.cancel()
            ticker = nil
        }
    }
}
