import Foundation

/// A time range of the source audio, in milliseconds, chosen for embedding.
public struct AudioSpan: Sendable, Equatable, Codable {
    public var startMs: Int
    public var endMs: Int

    /// Milliseconds of actual *speech* inside the span (sum of word
    /// durations), as opposed to wall-clock length. Two spans of equal length
    /// are not equally useful: the one with more voiced audio gives the
    /// embedding model more to work with, so this — not `durationMs` — is the
    /// ranking key.
    public var voicedMs: Int

    public init(startMs: Int, endMs: Int, voicedMs: Int) {
        self.startMs = startMs
        self.endMs = endMs
        self.voicedMs = voicedMs
    }

    public var durationMs: Int { max(0, endMs - startMs) }
    public var startSeconds: Double { Double(startMs) / 1000 }
    public var endSeconds: Double { Double(endMs) / 1000 }
    public var durationSeconds: Double { Double(durationMs) / 1000 }
}

/// The spans chosen for one diarized speaker ("A", "B", …).
public struct SpeakerSpanSelection: Sendable, Equatable {
    public var speaker: String
    public var spans: [AudioSpan]

    /// True when at least `targetSpansPerSpeaker` clean spans were found. A
    /// false here is the signal that an identification result for this
    /// speaker rests on thin evidence.
    public var meetsTarget: Bool

    public init(speaker: String, spans: [AudioSpan], meetsTarget: Bool) {
        self.speaker = speaker
        self.spans = spans
        self.meetsTarget = meetsTarget
    }

    public var totalVoicedMs: Int { spans.reduce(0) { $0 + $1.voicedMs } }
    public var totalDurationMs: Int { spans.reduce(0) { $0 + $1.durationMs } }
}

/// Picks the audio spans that represent each diarized speaker.
///
/// Spec §3 step 1 and plan §2 Phase 1 item 3: *per diarized speaker, pick 3–5
/// of their longest clean utterances — target 5–15 s spans, trimmed to word
/// boundaries, skipping spans that overlap another speaker's words.*
///
/// The three requirements map onto the implementation like this:
///
/// - **Trimmed to word boundaries.** Every span begins at some word's `start`
///   and ends at some word's `end`, never mid-word — so no span opens or
///   closes on a clipped syllable.
/// - **Clean.** A span is rejected if any *other* speaker's word overlaps it.
///   Cross-talk is exactly what poisons a speaker embedding, and diarization
///   already tells us where it is.
/// - **Longest.** Within each utterance the best window is the one carrying
///   the most voiced milliseconds while still fitting `maxSpanMs`; across
///   utterances, the highest-voiced windows win.
///
/// Fully deterministic: same transcript in, same spans out, with ties broken
/// by earlier start time. No randomness, no clock, no I/O — which is what
/// makes it unit-testable on synthetic data.
public struct UtteranceSelector: Sendable {

    public struct Configuration: Sendable, Equatable {
        /// Lower bound of the target span band.
        public var minSpanMs: Int
        /// Upper bound of the target span band. Also the width of the sliding
        /// window searched inside each utterance.
        public var maxSpanMs: Int
        /// Relaxed floor used **only** for a speaker who yields no span at
        /// `minSpanMs`. A short-turn participant ("yeah, agreed") would
        /// otherwise get no embedding at all, and no embedding means no
        /// chance of recognition — a weak span beats nothing, and the caller
        /// still sees `meetsTarget == false`.
        public var fallbackMinSpanMs: Int
        /// Hard cap on spans per speaker (spec: 3–5).
        public var maxSpansPerSpeaker: Int
        /// Desired spans per speaker; drives `meetsTarget` (spec: 3–5).
        public var targetSpansPerSpeaker: Int
        /// Padding applied around every foreign word before the overlap test.
        /// Diarization boundaries are approximate; a non-zero guard buys
        /// margin at the cost of discarding more audio. Tune in Phase 1b.
        public var overlapGuardMs: Int

        public init(
            minSpanMs: Int = 5_000,
            maxSpanMs: Int = 15_000,
            fallbackMinSpanMs: Int = 2_000,
            maxSpansPerSpeaker: Int = 5,
            targetSpansPerSpeaker: Int = 3,
            overlapGuardMs: Int = 0
        ) {
            self.minSpanMs = minSpanMs
            self.maxSpanMs = maxSpanMs
            self.fallbackMinSpanMs = fallbackMinSpanMs
            self.maxSpansPerSpeaker = maxSpansPerSpeaker
            self.targetSpansPerSpeaker = targetSpansPerSpeaker
            self.overlapGuardMs = overlapGuardMs
        }

        public static let `default` = Configuration()
    }

    public var configuration: Configuration

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    // MARK: - Selection

    /// Selects spans for every diarized speaker in a transcript.
    /// - Returns: One entry per speaker, ordered by speaker label. Speakers
    ///   with no usable span are still returned (with an empty `spans`) so the
    ///   caller can report them rather than silently dropping a participant.
    public func select(from response: TranscriptResponse) -> [SpeakerSpanSelection] {
        select(utterances: response.utterances ?? [], allWords: response.allWords)
    }

    public func select(
        utterances: [TranscriptResponse.Utterance],
        allWords: [TranscriptResponse.Word]
    ) -> [SpeakerSpanSelection] {
        let speakers = Set(utterances.map(\.speaker)).sorted()
        guard !speakers.isEmpty else { return [] }

        // Foreign-word ranges are per speaker and reused across all of that
        // speaker's utterances, so they're merged once here.
        var foreignRanges: [String: [ClosedTimeRange]] = [:]
        for speaker in speakers {
            let foreign = allWords.filter { word in
                guard let wordSpeaker = word.speaker else { return false }
                return wordSpeaker != speaker
            }
            foreignRanges[speaker] = Self.mergedRanges(of: foreign, guardMs: configuration.overlapGuardMs)
        }

        return speakers.map { speaker in
            let ranges = foreignRanges[speaker] ?? []
            var primary: [AudioSpan] = []
            var fallback: [AudioSpan] = []

            for utterance in utterances where utterance.speaker == speaker {
                let best = bestWindows(in: utterance, foreignRanges: ranges)
                if let span = best.primary { primary.append(span) }
                if let span = best.fallback { fallback.append(span) }
            }

            // Fall back only when the strict band produced nothing at all.
            let pool = primary.isEmpty ? fallback : primary
            let ranked = pool.sorted { lhs, rhs in
                lhs.voicedMs == rhs.voicedMs ? lhs.startMs < rhs.startMs : lhs.voicedMs > rhs.voicedMs
            }
            let chosen = Array(ranked.prefix(max(0, configuration.maxSpansPerSpeaker)))

            return SpeakerSpanSelection(
                speaker: speaker,
                spans: chosen,
                meetsTarget: !primary.isEmpty && chosen.count >= configuration.targetSpansPerSpeaker
            )
        }
    }

    // MARK: - Per-utterance window search

    private struct BestWindows {
        var primary: AudioSpan?
        var fallback: AudioSpan?
    }

    /// Finds, inside one utterance, the contiguous run of words that carries
    /// the most voiced time while (a) spanning at most `maxSpanMs` and (b) not
    /// overlapping any foreign word.
    ///
    /// Both constraints are monotone in the window's left edge — advancing it
    /// shrinks the span, which can only bring an over-long window back into
    /// budget and can only remove an overlapping foreign word — so a single
    /// two-pointer sweep is sufficient and the whole search is O(words).
    private func bestWindows(
        in utterance: TranscriptResponse.Utterance,
        foreignRanges: [ClosedTimeRange]
    ) -> BestWindows {
        let words = utterance.words.isEmpty
            ? Self.syntheticWords(for: utterance)
            : utterance.words.sorted { ($0.start, $0.end) < ($1.start, $1.end) }

        guard !words.isEmpty else { return BestWindows() }

        var result = BestWindows()
        var left = 0
        var voiced = 0

        for right in words.indices {
            voiced += max(0, words[right].durationMs)

            while left <= right {
                let start = words[left].start
                let end = words[right].end
                let spanTooLong = (end - start) > configuration.maxSpanMs
                let dirty = Self.intersects(ranges: foreignRanges, start: start, end: end)
                guard spanTooLong || dirty else { break }
                voiced -= max(0, words[left].durationMs)
                left += 1
            }

            guard left <= right else {
                voiced = 0
                continue
            }

            let span = AudioSpan(
                startMs: words[left].start,
                endMs: words[right].end,
                voicedMs: voiced
            )
            guard span.durationMs > 0 else { continue }

            if span.durationMs >= configuration.minSpanMs {
                result.primary = Self.better(result.primary, span)
            }
            if span.durationMs >= configuration.fallbackMinSpanMs {
                result.fallback = Self.better(result.fallback, span)
            }
        }

        return result
    }

    /// Higher voiced time wins; ties go to the earlier span, so the result
    /// never depends on iteration order.
    private static func better(_ current: AudioSpan?, _ candidate: AudioSpan) -> AudioSpan {
        guard let current else { return candidate }
        if candidate.voicedMs != current.voicedMs {
            return candidate.voicedMs > current.voicedMs ? candidate : current
        }
        return candidate.startMs < current.startMs ? candidate : current
    }

    /// An utterance with no word-level detail still has its own start/end.
    /// Treat that as a single word so such transcripts degrade to
    /// utterance-boundary spans rather than being dropped.
    private static func syntheticWords(for utterance: TranscriptResponse.Utterance) -> [TranscriptResponse.Word] {
        guard utterance.end > utterance.start else { return [] }
        return [
            TranscriptResponse.Word(
                text: utterance.text,
                start: utterance.start,
                end: utterance.end,
                confidence: utterance.confidence ?? 1,
                speaker: utterance.speaker
            )
        ]
    }

    // MARK: - Foreign-word ranges

    struct ClosedTimeRange: Equatable {
        var start: Int
        var end: Int
    }

    /// Collapses the other speakers' words into disjoint, sorted ranges so the
    /// overlap test is a binary search instead of a scan over every word.
    static func mergedRanges(of words: [TranscriptResponse.Word], guardMs: Int) -> [ClosedTimeRange] {
        var padded: [ClosedTimeRange] = []
        padded.reserveCapacity(words.count)
        for word in words {
            let range = ClosedTimeRange(start: word.start - guardMs, end: word.end + guardMs)
            if range.end > range.start { padded.append(range) }
        }
        padded.sort { (lhs: ClosedTimeRange, rhs: ClosedTimeRange) -> Bool in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            return lhs.end < rhs.end
        }

        var merged: [ClosedTimeRange] = []
        for range in padded {
            if var last = merged.last, range.start <= last.end {
                last.end = max(last.end, range.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// Whether `[start, end)` touches any of the (disjoint, sorted) ranges.
    ///
    /// Only the last range starting before `end` needs checking: the ranges
    /// are disjoint and ordered, so if that one ends at or before `start`,
    /// every earlier one does too.
    static func intersects(ranges: [ClosedTimeRange], start: Int, end: Int) -> Bool {
        guard !ranges.isEmpty, end > start else { return false }

        var low = 0
        var high = ranges.count - 1
        var candidate = -1
        while low <= high {
            let mid = (low + high) / 2
            if ranges[mid].start < end {
                candidate = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        guard candidate >= 0 else { return false }
        return ranges[candidate].end > start
    }
}
