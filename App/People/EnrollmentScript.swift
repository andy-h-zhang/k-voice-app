import Foundation

/// The text a person reads during guided enrollment (spec §Voice profiles:
/// "the person reads ~30 seconds of on-screen text").
///
/// ## Why this text
///
/// The embedding model characterizes a *voice*, not a vocabulary, so what
/// matters is that someone reads it the way they actually talk. Three
/// constraints shaped it:
///
/// - **Natural to say out loud.** No tongue-twisters, no corporate filler, no
///   sentence anyone would feel silly reading in an open-plan office. A
///   self-conscious reader adopts a "reading voice", which is exactly the
///   voice that will *not* show up in the meeting we are trying to match.
/// - **Phonetically varied.** Ordinary sentences that between them cover open
///   and closed vowels, plosives, fricatives and nasals, rather than one
///   register repeated.
/// - **Long enough to window.** ~30 seconds at an unhurried pace, which
///   `AudioSpanExtractor` cuts into six 5-second embeddings — several vectors
///   modelling one session's variation, not one averaged vector (plan §3 risk 9).
///
/// The lines are separate so the sheet can highlight roughly where the reader
/// should be, which is what stops people racing to the end in eight seconds.
enum EnrollmentScript {

    /// Target read length. Capture stops itself here.
    static let targetDuration: TimeInterval = 30

    /// Below this there is not enough audio to window into usable embeddings,
    /// so "Stop early" is refused with an explanation rather than silently
    /// producing a thin profile.
    static let minimumDuration: TimeInterval = 10

    static let lines: [String] = [
        "I'm setting up a voice profile so this app can tell who is speaking in a meeting.",
        "I'll read for about half a minute in my normal voice — there's no need to slow down "
            + "or pronounce anything carefully.",
        "The weather this week keeps changing its mind: bright mornings, grey afternoons, "
            + "and rain that arrives the moment I leave the house.",
        "For lunch I usually put together whatever is in the fridge, and I drink far more "
            + "coffee than I plan to.",
        "Later I'll join a call, share a few numbers, and argue politely about the schedule.",
        "That should be plenty. Thanks for listening."
    ]

    /// Roughly which line the reader should be on, `0..<lines.count`, given how
    /// long they have been going.
    ///
    /// Proportional rather than measured: this is a reading *guide*, and a
    /// highlight that lags a fast reader is better than one that hurries a slow
    /// one, since the recording runs the full duration either way.
    static func lineIndex(atElapsed elapsed: TimeInterval) -> Int {
        guard targetDuration > 0, !lines.isEmpty else { return 0 }
        let fraction = min(max(elapsed / targetDuration, 0), 0.999)
        return min(lines.count - 1, Int(fraction * Double(lines.count)))
    }
}
