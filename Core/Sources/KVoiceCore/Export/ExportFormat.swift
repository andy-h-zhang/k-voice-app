import Foundation

/// The export formats offered per recording (`docs/spec.md` §Export).
///
/// `RawValue`-backed and `Codable` because one of these is stored in
/// UserDefaults as the user's default export format (`docs/spec.md`
/// §Settings); the raw values are therefore persisted and must not change.
public enum ExportFormat: String, CaseIterable, Codable, Sendable {
    case markdown
    case plainText
    case word

    /// Path extension, without the dot.
    public var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .plainText: return "txt"
        case .word: return "docx"
        }
    }

    /// Name for menus and settings.
    public var displayName: String {
        switch self {
        case .markdown: return "Markdown"
        case .plainText: return "Plain Text"
        case .word: return "Word"
        }
    }

    /// The format's UTI, for drag-out and save panels.
    public var uniformTypeIdentifier: String {
        switch self {
        case .markdown: return "net.daringfireball.markdown"
        case .plainText: return "public.plain-text"
        case .word: return "org.openxmlformats.wordprocessingml.document"
        }
    }
}
