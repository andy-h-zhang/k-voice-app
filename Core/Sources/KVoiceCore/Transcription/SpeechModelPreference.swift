import Foundation

/// Which AssemblyAI speech model a transcription asks for.
///
/// `speech_models` is a **priority-ordered array**, not a scalar (api-notes §2):
/// the server serves the first model it can and echoes which one in
/// `speech_model_used`. So the interesting choice is not only *which* model but
/// *whether to allow a fallback at all*, and this enum is the small set of
/// combinations worth offering rather than a free-form list.
///
/// ## Why "no fallback" is the default
///
/// Shipping `["universal-3-5-pro", "universal-2"]` looks like belt and braces
/// and quietly costs something. `TranscriptRequest.keytermWordBudget` takes the
/// **lowest** budget among the models sent — it has to, since any of them may
/// serve the request — so naming `universal-2` as a fallback caps keyterms at
/// 200 words instead of ~1,000, on every request, whether or not the fallback
/// is ever used. A user who has typed 40 domain terms is silently losing most of
/// them to insure against an outage.
///
/// Asking for one model makes an outage an honest error the user can retry,
/// rather than a transcript that came back quietly worse.
public enum SpeechModelPreference: String, Sendable, Equatable, CaseIterable, Identifiable {

    /// `universal-3-5-pro` alone. The default.
    case universal3Pro = "universal-3-5-pro"

    /// `universal-3-5-pro`, with `universal-2` as a fallback.
    case universal3ProWithFallback = "universal-3-5-pro+universal-2"

    /// `universal-2` alone.
    case universal2 = "universal-2"

    public var id: String { rawValue }

    public static let `default` = SpeechModelPreference.universal3Pro

    /// Exactly what goes into `speech_models`, in priority order.
    public var speechModels: [String] {
        switch self {
        case .universal3Pro: return ["universal-3-5-pro"]
        case .universal3ProWithFallback: return ["universal-3-5-pro", "universal-2"]
        case .universal2: return ["universal-2"]
        }
    }

    public var displayName: String {
        switch self {
        case .universal3Pro: return "Universal 3.5 Pro"
        case .universal3ProWithFallback: return "Universal 3.5 Pro, then Universal 2"
        case .universal2: return "Universal 2"
        }
    }

    /// What choosing this costs or buys, in the user's terms.
    public var explanation: String {
        switch self {
        case .universal3Pro:
            return """
                The best model, and the only one asked for. Keyterms get the full \
                \(AssemblyAIConstants.maxKeytermWordsUniversal3.formatted())-word budget. If it is \
                unavailable the transcription fails and can be retried, rather than \
                quietly coming back from a weaker model.
                """
        case .universal3ProWithFallback:
            return """
                Falls back to Universal 2 when 3.5 Pro is unavailable, so a transcription \
                rarely fails outright — but every request is capped at the lower \
                \(AssemblyAIConstants.maxKeytermWordsUniversal2.formatted())-word keyterm budget, \
                because either model might serve it.
                """
        case .universal2:
            return """
                The older model. Cheaper and still diarizes, with a \
                \(AssemblyAIConstants.maxKeytermWordsUniversal2.formatted())-word keyterm budget and \
                noticeably weaker accuracy on names and jargon.
                """
        }
    }

    /// The keyterm word budget in force for this choice.
    public var keytermWordBudget: Int {
        TranscriptRequest.keytermWordBudget(for: speechModels)
    }
}
