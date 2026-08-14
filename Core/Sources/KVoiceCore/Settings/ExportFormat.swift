import Foundation

/// The three export formats from spec §Export.
///
/// Lives here because `Export/` is where Phase 7's renderers land; Phase 3
/// needs the type early because "default export format" is one of the settings
/// (spec §Settings) and a settings value has to have a type before it has a UI.
public enum ExportFormat: String, Codable, Sendable, CaseIterable {
    /// `## Speaker — [hh:mm:ss]` turn headers with paragraphs.
    case markdown
    /// The same structure, no markup.
    case plainText
    /// OOXML `.docx`: speaker names bold, timestamps subdued.
    case docx

    /// File extension, without the dot.
    public var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .plainText: return "txt"
        case .docx: return "docx"
        }
    }

    public var displayName: String {
        switch self {
        case .markdown: return "Markdown"
        case .plainText: return "Plain Text"
        case .docx: return "Word (.docx)"
        }
    }
}
