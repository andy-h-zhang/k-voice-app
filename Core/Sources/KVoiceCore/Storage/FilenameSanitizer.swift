import Foundation

/// Turns a user-typed recording title into a filename that is safe on disk
/// and sane in Finder.
///
/// Recording titles are renamed inline by the user (`docs/spec.md`
/// §Library), and the title becomes a folder name, an `.m4a` name, and the
/// baseline for export filenames — so this runs on every rename, and it must
/// never return something the filesystem will reject.
///
/// Rules, in order:
///
/// 1. Characters that are illegal or hostile in a path — `/ \ : * ? " < > |`
///    and any control character — become spaces. (APFS only forbids `/` and
///    NUL, but Finder renders `:` as `/`, and exports travel to other
///    machines.)
/// 2. Runs of whitespace collapse to one space; leading/trailing whitespace
///    goes away.
/// 3. Leading and trailing dots are trimmed — a leading dot hides the file,
///    a trailing one confuses extension handling, and `.`/`..` are not names.
/// 4. The result is capped in both characters and UTF-8 bytes (an APFS path
///    component tops out at 255 bytes; the cap leaves room for `.docx` and a
///    ` 2` collision suffix).
/// 5. If nothing survives, a fallback name is used — this never returns an
///    empty string.
public enum FilenameSanitizer {
    /// Used when a title sanitizes down to nothing.
    public static let fallbackName = "Untitled"

    /// Character cap. Well under the filesystem limit; long enough for a
    /// descriptive meeting title, short enough to stay readable in Finder.
    public static let maxCharacters = 120

    /// UTF-8 byte cap. APFS allows 255 per component; the headroom covers a
    /// collision suffix plus the longest export extension.
    public static let maxUTF8Bytes = 200

    /// Characters replaced with a space.
    private static let illegalCharacters: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]

    /// Trimmed from both ends after cleaning.
    private static let trimmedCharacters = CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines)

    // MARK: - Sanitizing

    /// Sanitizes `title` into a usable filename base (no extension).
    ///
    /// - Returns: A non-empty name, at most `maxCharacters` characters and
    ///   `maxUTF8Bytes` UTF-8 bytes.
    public static func sanitize(
        _ title: String,
        fallback: String = fallbackName,
        maxCharacters: Int = maxCharacters,
        maxUTF8Bytes: Int = maxUTF8Bytes
    ) -> String {
        let cleaned = clean(title, maxCharacters: maxCharacters, maxUTF8Bytes: maxUTF8Bytes)
        if !cleaned.isEmpty { return cleaned }

        let cleanedFallback = clean(fallback, maxCharacters: maxCharacters, maxUTF8Bytes: maxUTF8Bytes)
        return cleanedFallback.isEmpty ? fallbackName : cleanedFallback
    }

    private static func clean(_ raw: String, maxCharacters: Int, maxUTF8Bytes: Int) -> String {
        var mapped = String()
        mapped.reserveCapacity(raw.count)
        for character in raw {
            if illegalCharacters.contains(character) {
                mapped.append(" ")
            } else if character.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
                mapped.append(" ")
            } else {
                mapped.append(character)
            }
        }

        // Collapses interior whitespace runs and trims the ends in one step.
        let collapsed = mapped.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: trimmedCharacters)

        return truncate(trimmed, maxCharacters: maxCharacters, maxUTF8Bytes: maxUTF8Bytes)
    }

    /// Truncates to both caps, then re-trims — cutting mid-name can expose a
    /// trailing space or dot.
    private static func truncate(_ value: String, maxCharacters: Int, maxUTF8Bytes: Int) -> String {
        guard maxCharacters > 0, maxUTF8Bytes > 0 else { return "" }

        var result = value.count > maxCharacters ? String(value.prefix(maxCharacters)) : value
        while result.utf8.count > maxUTF8Bytes, !result.isEmpty {
            result.removeLast()
        }
        return result.trimmingCharacters(in: trimmedCharacters)
    }

    // MARK: - Collision handling

    /// Returns `base`, or the first free ` 2`, ` 3`, … variant of it.
    ///
    /// - Parameter isTaken: Whether a candidate name is already in use. The
    ///   store passes a filesystem check; tests pass a set.
    public static func uniqueName(
        for base: String,
        maxCharacters: Int = maxCharacters,
        maxUTF8Bytes: Int = maxUTF8Bytes,
        isTaken: (String) -> Bool
    ) -> String {
        guard isTaken(base) else { return base }

        for index in 2...999 {
            let candidate = applySuffix(
                " \(index)",
                to: base,
                maxCharacters: maxCharacters,
                maxUTF8Bytes: maxUTF8Bytes
            )
            if !isTaken(candidate) { return candidate }
        }

        // 998 collisions on one title is not a real scenario, but the
        // function stays total rather than looping forever.
        return applySuffix(
            " \(UUID().uuidString.prefix(8))",
            to: base,
            maxCharacters: maxCharacters,
            maxUTF8Bytes: maxUTF8Bytes
        )
    }

    /// Appends a collision suffix, shortening `base` so the total still fits
    /// under both caps.
    private static func applySuffix(
        _ suffix: String,
        to base: String,
        maxCharacters: Int,
        maxUTF8Bytes: Int
    ) -> String {
        var shortened = base
        if shortened.count + suffix.count > maxCharacters {
            shortened = String(shortened.prefix(max(0, maxCharacters - suffix.count)))
        }
        while shortened.utf8.count + suffix.utf8.count > maxUTF8Bytes, !shortened.isEmpty {
            shortened.removeLast()
        }

        // Shortening can leave a trailing space or dot right before the
        // suffix ("Weekly sync " + " 2").
        shortened = shortened.trimmingCharacters(in: trimmedCharacters)
        if shortened.isEmpty { shortened = fallbackName }

        return shortened + suffix
    }
}
