import AVFoundation
import Foundation
import KVoiceCore
import Observation

/// Synced playback for the transcript editor (spec §Library and editor: "click
/// a segment to jump audio; highlight the current segment during playback").
///
/// ## Why `AVAudioPlayer`
///
/// The file is a finished local `.m4a`. `AVAudioPlayer` opens it synchronously,
/// reports `duration` immediately, and takes a plain `TimeInterval` seek — no
/// `AVPlayerItem` status to wait on, no `CMTime` conversions, no KVO. `AVPlayer`
/// would buy streaming and remote URLs, neither of which exists here.
///
/// ## How the highlight stays in sync
///
/// A 10 Hz tick reads `currentTime` and resolves it against the utterance spans
/// (`startMs`/`endMs` from the rows — plan §3 decision 5: segment-level sync is
/// all the persisted timings need to support). ``currentUtteranceIndex`` is
/// assigned **only when it changes**, which matters: `currentTime` moves ten
/// times a second and the transport bar is the only thing reading it, while the
/// highlight moves once per utterance and hundreds of paragraph views read
/// *that*. Observation is per-property, so the paragraphs re-render once a turn
/// rather than ten times a second.
@MainActor
@Observable
final class TranscriptPlayback {

    // MARK: - Observed state

    private(set) var isPlaying = false

    /// Playhead position in seconds. Moves at the tick rate.
    private(set) var currentTime: TimeInterval = 0

    /// Length of the audio file, in seconds.
    private(set) var duration: TimeInterval = 0

    /// The utterance the playhead is inside, or the last one it passed.
    /// Changes at most once per utterance.
    private(set) var currentUtteranceIndex: Int?

    /// Non-nil when the audio could not be opened — a moved or deleted file.
    private(set) var loadFailure: String?

    /// Whether there is a player to drive.
    ///
    /// A stored, *observed* property rather than `player != nil`: the player
    /// itself is `@ObservationIgnored`, so a computed version would never
    /// invalidate the transport bar that reads it, and the controls would stay
    /// disabled after the audio finished loading. (It happens to recover today
    /// because the same view also reads `duration` — which is exactly the kind
    /// of accident worth removing.)
    private(set) var isLoaded = false

    /// True while the user drags the scrubber, so ticks stop fighting the drag.
    var isScrubbing = false {
        didSet {
            guard oldValue, !isScrubbing else { return }
            seek(to: currentTime)
        }
    }

    // MARK: - Unobserved state

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    /// `(utterance index, start, end)` in seconds, sorted by start.
    @ObservationIgnored private var spans: [(index: Int, start: TimeInterval, end: TimeInterval)] = []

    /// Tick period. 10 Hz is well under a spoken syllable and costs nothing;
    /// the highlight only actually publishes when it crosses a boundary.
    static let tickInterval = Duration.milliseconds(100)

    // MARK: - Loading

    /// Opens the recording's audio. Safe to call repeatedly.
    func load(url: URL) {
        guard player == nil else { return }

        guard FileManager.default.fileExists(atPath: url.path) else {
            loadFailure = "The audio file is missing from \(url.deletingLastPathComponent().path)."
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            self.player = player
            duration = player.duration
            isLoaded = true
            loadFailure = nil
        } catch {
            loadFailure = "Could not open the audio: \(error.localizedDescription)"
        }
    }

    /// Supplies the spans the highlight resolves against.
    ///
    /// Sorted by start so the lookup can binary-search: transcripts are
    /// time-ordered already, but nothing in the schema *guarantees* it, and a
    /// mis-sorted array would make the search silently wrong rather than slow.
    func setSpans(_ utterances: [EditorUtterance]) {
        spans = utterances
            .map { (index: $0.index, start: Double($0.startMs) / 1_000, end: Double($0.endMs) / 1_000) }
            .sorted { $0.start < $1.start }
        updateHighlight()
    }

    // MARK: - Transport

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let player else { return }
        // Restart from the top when the playhead is parked at the end,
        // rather than playing nothing.
        if player.currentTime >= duration - 0.05 { player.currentTime = 0 }
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

    /// Moves the playhead. Playback continues if it was running.
    func seek(to time: TimeInterval) {
        guard let player else { return }
        let clamped = min(max(0, time), max(0, duration))
        player.currentTime = clamped
        currentTime = clamped
        updateHighlight()
    }

    func skip(by delta: TimeInterval) {
        seek(to: currentTime + delta)
    }

    /// Moves the *displayed* playhead without touching the player.
    ///
    /// What a scrubber drag does: seeking the audio on every intermediate value
    /// makes AAC stutter, so the drag only moves the readout and the highlight,
    /// and releasing it (`isScrubbing` going false) performs one real seek.
    func scrub(to time: TimeInterval) {
        currentTime = min(max(0, time), max(0, duration))
        updateHighlight()
    }

    /// Click-to-seek: jump to the start of an utterance and highlight it at
    /// once, without waiting for the next tick.
    func seek(toUtterance index: Int) {
        guard let span = spans.first(where: { $0.index == index }) else { return }
        seek(to: span.start)
        currentUtteranceIndex = index
    }

    /// Seek + play, for "play from here".
    func playFrom(utterance index: Int) {
        seek(toUtterance: index)
        if !isPlaying { play() }
    }

    /// Releases the audio device. Called when the editor goes away.
    func stop() {
        ticker?.cancel()
        ticker = nil
        player?.stop()
        player = nil
        isLoaded = false
        isPlaying = false
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
            // playhead there rather than wherever the last tick happened to
            // read, so the scrubber lands exactly at the end of the file.
            currentTime = duration
            isPlaying = false
        }
        updateHighlight()
    }

    // MARK: - Highlight

    private func updateHighlight() {
        let resolved = span(at: currentTime)
        // Assign only on change — this is what keeps hundreds of paragraph
        // views from re-rendering ten times a second.
        if resolved != currentUtteranceIndex { currentUtteranceIndex = resolved }
    }

    /// The utterance covering `time`, or the most recent one that started
    /// before it.
    ///
    /// Gaps between utterances (breaths, pauses, the provider trimming silence)
    /// keep the previous line lit rather than blanking the highlight — the
    /// alternative flickers on every pause, and "who is speaking" is still that
    /// person until someone else starts.
    private func span(at time: TimeInterval) -> Int? {
        guard !spans.isEmpty else { return nil }
        guard time >= spans[0].start else { return nil }

        var low = 0
        var high = spans.count - 1
        var candidate = 0
        while low <= high {
            let mid = (low + high) / 2
            if spans[mid].start <= time {
                candidate = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return spans[candidate].index
    }
}
