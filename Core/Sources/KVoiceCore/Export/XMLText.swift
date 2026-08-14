import Foundation

/// Escaping for text placed inside an XML element.
///
/// Transcript text is user data twice over — spoken words plus inline edits —
/// so it reaches the `.docx` writer containing whatever the speaker said and
/// the user typed. An unescaped `&` or `<` does not produce a slightly wrong
/// document; it produces a package Word refuses to open.
enum XMLText {

    /// Escapes `raw` for use as element content and drops characters XML 1.0
    /// cannot represent at all.
    ///
    /// All five predefined entities are escaped, including quotes: the same
    /// helper is safe to reuse for an attribute value, and over-escaping is
    /// invisible to the reader while under-escaping is fatal.
    ///
    /// Control characters below U+0020 (other than tab, newline and carriage
    /// return) and the non-characters U+FFFE/U+FFFF are *illegal* in XML 1.0 —
    /// no escape exists for them — so they are dropped rather than encoded.
    /// Everything else, including every non-ASCII character, passes through
    /// unchanged and is carried by the part's UTF-8 encoding.
    static func escaped(_ raw: String) -> String {
        var result = ""
        result.reserveCapacity(raw.unicodeScalars.count)

        for scalar in raw.unicodeScalars {
            switch scalar {
            case "&": result.append("&amp;")
            case "<": result.append("&lt;")
            case ">": result.append("&gt;")
            case "\"": result.append("&quot;")
            case "'": result.append("&apos;")
            default:
                if isLegal(scalar) { result.unicodeScalars.append(scalar) }
            }
        }

        return result
    }

    /// Whether a scalar is representable in XML 1.0 element content.
    private static func isLegal(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A, 0x0D: return true          // tab, LF, CR
        case 0x00..<0x20: return false              // other C0 controls
        case 0xFFFE, 0xFFFF: return false           // non-characters
        default: return true
        }
    }
}
