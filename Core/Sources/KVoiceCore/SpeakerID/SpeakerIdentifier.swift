import Foundation

/// The result for one diarized speaker: which spans were used, the cluster
/// embedding they produced, and who it matched.
public struct SpeakerIdentification: Sendable {
    /// Diarized label from the API ("A", "B", …).
    public var speaker: String
    /// Spans actually embedded (a subset of the selected ones if any failed).
    public var spans: [AudioSpan]
    /// False when fewer than the target number of clean spans were available —
    /// the verdict rests on thin evidence.
    public var meetsTarget: Bool
    /// L2-normalized average of the span embeddings. Nil when no span could be
    /// embedded at all.
    public var clusterEmbedding: [Float]?
    /// Nil only when `clusterEmbedding` is nil.
    public var match: SpeakerMatch?
    /// Non-fatal problems (a span that failed to decode, a too-short span…).
    public var warnings: [String]

    public init(
        speaker: String,
        spans: [AudioSpan],
        meetsTarget: Bool,
        clusterEmbedding: [Float]?,
        match: SpeakerMatch?,
        warnings: [String] = []
    ) {
        self.speaker = speaker
        self.spans = spans
        self.meetsTarget = meetsTarget
        self.clusterEmbedding = clusterEmbedding
        self.match = match
        self.warnings = warnings
    }

    public var totalVoicedMs: Int { spans.reduce(0) { $0 + $1.voicedMs } }
}

/// End-to-end speaker identification: transcript + audio → named speakers.
///
/// Wires spec §3's five steps together in order:
/// select spans (`UtteranceSelector`) → extract audio (`AudioSpanExtractor`)
/// → embed (`SpeakerEmbedder`) → average into a cluster embedding
/// (`VectorMath.centroid`) → cosine-match (`ClusterMatcher`).
///
/// The embedder is injected as an existential, so this whole pipeline runs in
/// tests against a deterministic stub — no model download, no network. The
/// real `FluidAudioEmbedder` is only ever constructed by the CLI.
public struct SpeakerIdentifier: Sendable {

    public var selector: UtteranceSelector
    public var matcher: ClusterMatcher
    public var extractor: AudioSpanExtractor

    private let embedder: any SpeakerEmbedder

    public init(
        embedder: any SpeakerEmbedder,
        selector: UtteranceSelector = UtteranceSelector(),
        matcher: ClusterMatcher = ClusterMatcher(),
        extractor: AudioSpanExtractor = AudioSpanExtractor()
    ) {
        self.embedder = embedder
        self.selector = selector
        self.matcher = matcher
        self.extractor = extractor
    }

    /// Identifies every diarized speaker in `transcript` against `library`.
    ///
    /// A speaker whose audio can't be embedded is returned with a nil
    /// `clusterEmbedding` and a warning rather than throwing: one unusable
    /// participant must not sink the whole recording.
    public func identify(
        audioURL: URL,
        transcript: TranscriptResponse,
        library: ProfileLibrary,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> [SpeakerIdentification] {
        let selections = selector.select(from: transcript)
        var results: [SpeakerIdentification] = []
        results.reserveCapacity(selections.count)

        for selection in selections {
            onProgress?(
                "Speaker \(selection.speaker): \(selection.spans.count) span(s), "
                    + String(format: "%.1fs voiced", Double(selection.totalVoicedMs) / 1000)
            )

            var warnings: [String] = []
            var used: [AudioSpan] = []
            var vectors: [[Float]] = []

            if selection.spans.isEmpty {
                warnings.append("no clean span of usable length — speaker cannot be identified")
            }

            for span in selection.spans {
                do {
                    let samples = try extractor.samples(from: audioURL, span: span)
                    let vector = try await embedder.embedding(for: samples)
                    vectors.append(vector)
                    used.append(span)
                } catch {
                    warnings.append(
                        String(
                            format: "span %.2fs–%.2fs skipped: %@",
                            span.startSeconds,
                            span.endSeconds,
                            (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                        )
                    )
                }
            }

            let cluster = VectorMath.centroid(vectors)
            results.append(
                SpeakerIdentification(
                    speaker: selection.speaker,
                    spans: used,
                    meetsTarget: selection.meetsTarget && used.count == selection.spans.count,
                    clusterEmbedding: cluster,
                    match: cluster.map { matcher.match(cluster: $0, in: library) },
                    warnings: warnings
                )
            )
        }

        return results
    }

    /// Embeds a set of clips and averages them — the enrollment path
    /// (`speakerlab enroll`). Each clip is windowed, so a 30 s read yields
    /// several embeddings rather than one blurred average (plan §3 risk 9).
    ///
    /// - Returns: One L2-normalized embedding per window, in clip order.
    public func enrollmentEmbeddings(
        clips: [URL],
        windowSeconds: Double = 5,
        minWindowSeconds: Double = 2,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> [[Float]] {
        var vectors: [[Float]] = []

        for clip in clips {
            let windows = try extractor.windows(
                from: clip,
                windowSeconds: windowSeconds,
                minWindowSeconds: minWindowSeconds
            )
            onProgress?("\(clip.lastPathComponent): \(windows.count) window(s)")

            for window in windows {
                do {
                    vectors.append(try await embedder.embedding(for: window))
                } catch {
                    onProgress?(
                        "  skipped a window: "
                            + ((error as? LocalizedError)?.errorDescription ?? String(describing: error))
                    )
                }
            }
        }

        return vectors
    }
}
