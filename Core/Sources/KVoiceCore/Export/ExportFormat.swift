import Foundation

/// The transcript formats written into every recording's folder
/// (`docs/spec.md` §Export).
///
/// Both cases are written, always, and kept current as the transcript is
/// edited — there is no per-user default to choose between them any more. The
/// enum survives because the two renderers, the two filenames and the two drag
/// chips all need to name a format.
///
/// Word was removed along with the shared `Transcripts/` folder: a `.docx` is a
/// document you *send*, and producing one on every keystroke to sit unread in a
/// project folder is not that. `.docx` files an earlier version wrote are moved
/// into their project folders by the layout migration and then left alone.
///
/// `RawValue`-backed and `Codable` because the raw values reached UserDefaults
/// in earlier versions; they must not change.
public enum ExportFormat: String, CaseIterable, Codable, Sendable {
    case markdown
    case plainText

    /// Path extension, without the dot.
    public var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .plainText: return "txt"
        }
    }

    /// Name for menus and help text.
    public var displayName: String {
        switch self {
        case .markdown: return "Markdown"
        case .plainText: return "Plain Text"
        }
    }

    /// The format's UTI, for drag-out.
    public var uniformTypeIdentifier: String {
        switch self {
        case .markdown: return "net.daringfireball.markdown"
        case .plainText: return "public.plain-text"
        }
    }
}
