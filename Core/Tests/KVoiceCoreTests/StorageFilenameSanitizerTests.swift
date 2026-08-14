import Foundation
import Testing
@testable import KVoiceCore

/// Filename sanitizing. Every recording title goes through this on create and
/// on every inline rename, so the invariant that matters most is: it never
/// returns something the filesystem or Finder will reject.
@Suite("Storage filename sanitizer")
struct StorageFilenameSanitizerTests {
    // MARK: - Ordinary titles

    @Test("an already-clean title is left alone")
    func cleanTitleIsUnchanged() {
        #expect(FilenameSanitizer.sanitize("2026-08-13 Standup") == "2026-08-13 Standup")
    }

    @Test("letters, digits, dashes and interior dots survive")
    func harmlessCharactersSurvive() {
        #expect(FilenameSanitizer.sanitize("Q3 review - v2.1 (final)") == "Q3 review - v2.1 (final)")
    }

    @Test("non-ASCII titles are preserved")
    func unicodeIsPreserved() {
        #expect(FilenameSanitizer.sanitize("会議 2026") == "会議 2026")
        #expect(FilenameSanitizer.sanitize("Café résumé") == "Café résumé")
    }

    // MARK: - Illegal characters

    @Test("path separators become spaces instead of splitting the path")
    func pathSeparatorsBecomeSpaces() {
        #expect(FilenameSanitizer.sanitize("Q1/Q2 Review") == "Q1 Q2 Review")
        #expect(FilenameSanitizer.sanitize("back\\slash") == "back slash")
    }

    /// Finder renders `:` as `/`, which makes a colon in a filename look like
    /// a directory boundary to the user.
    @Test("colons become spaces")
    func colonsBecomeSpaces() {
        #expect(FilenameSanitizer.sanitize("10:30 Standup") == "10 30 Standup")
    }

    @Test("characters illegal on other platforms are stripped too, for exports")
    func crossPlatformIllegalCharactersAreStripped() {
        #expect(FilenameSanitizer.sanitize("what?*<>|\"") == "what")
        #expect(FilenameSanitizer.sanitize("Sales * Q1") == "Sales Q1")
        #expect(FilenameSanitizer.sanitize("?*<>|\"") == "Untitled")
    }

    @Test("control characters and NUL become spaces")
    func controlCharactersBecomeSpaces() {
        #expect(FilenameSanitizer.sanitize("a\u{0}b") == "a b")
        #expect(FilenameSanitizer.sanitize("Meeting\nNotes") == "Meeting Notes")
        #expect(FilenameSanitizer.sanitize("Meeting\tNotes") == "Meeting Notes")
        #expect(FilenameSanitizer.sanitize("bell\u{7}here") == "bell here")
    }

    @Test("whitespace runs collapse to a single space")
    func whitespaceCollapses() {
        #expect(FilenameSanitizer.sanitize("too    many     spaces") == "too many spaces")
        #expect(FilenameSanitizer.sanitize("a//b") == "a b")
    }

    // MARK: - Dots and spaces at the edges

    @Test("leading dots are trimmed so the file is not hidden")
    func leadingDotsAreTrimmed() {
        #expect(FilenameSanitizer.sanitize(".hidden") == "hidden")
        #expect(FilenameSanitizer.sanitize("...hidden") == "hidden")
    }

    @Test("trailing dots and spaces are trimmed")
    func trailingDotsAndSpacesAreTrimmed() {
        #expect(FilenameSanitizer.sanitize("Report.") == "Report")
        #expect(FilenameSanitizer.sanitize("Report   ") == "Report")
        #expect(FilenameSanitizer.sanitize("  .. Report .. ") == "Report")
    }

    @Test("the current and parent directory names are not filenames")
    func dotDirectoriesAreRejected() {
        #expect(FilenameSanitizer.sanitize(".") == "Untitled")
        #expect(FilenameSanitizer.sanitize("..") == "Untitled")
    }

    // MARK: - Never empty

    @Test("an empty or all-illegal title falls back to a usable name")
    func emptyTitlesFallBack() {
        #expect(FilenameSanitizer.sanitize("") == "Untitled")
        #expect(FilenameSanitizer.sanitize("   ") == "Untitled")
        #expect(FilenameSanitizer.sanitize("///") == "Untitled")
        #expect(FilenameSanitizer.sanitize("\u{0}\u{1}") == "Untitled")
    }

    @Test("a caller-supplied fallback is used, and is itself sanitized")
    func customFallbackIsSanitized() {
        #expect(FilenameSanitizer.sanitize("", fallback: "New Recording") == "New Recording")
        #expect(FilenameSanitizer.sanitize("", fallback: "///") == "Untitled")
    }

    @Test("sanitizing never returns an empty string, for any input")
    func neverReturnsEmpty() {
        let inputs = ["", " ", ".", "..", "...", "/", "\u{0}", "?*|", "\n\t", "  ..  "]
        for input in inputs {
            #expect(!FilenameSanitizer.sanitize(input).isEmpty)
        }
    }

    // MARK: - Length caps

    @Test("long titles are capped in characters")
    func longTitlesAreCapped() {
        let long = String(repeating: "a", count: 500)
        let sanitized = FilenameSanitizer.sanitize(long)
        #expect(sanitized.count == FilenameSanitizer.maxCharacters)
    }

    /// APFS limits a path component to 255 UTF-8 bytes, and multi-byte
    /// scripts hit that long before the character cap.
    @Test("multi-byte titles are capped in UTF-8 bytes, not just characters")
    func multiByteTitlesRespectTheByteCap() {
        let long = String(repeating: "会", count: 300)          // 3 bytes each
        let sanitized = FilenameSanitizer.sanitize(long)
        #expect(sanitized.utf8.count <= FilenameSanitizer.maxUTF8Bytes)
        #expect(!sanitized.isEmpty)
    }

    @Test("emoji are not cut in half by the byte cap")
    func emojiAreNotSplit() {
        let long = String(repeating: "👩‍👩‍👧‍👦", count: 50)
        let sanitized = FilenameSanitizer.sanitize(long)
        #expect(sanitized.utf8.count <= FilenameSanitizer.maxUTF8Bytes)
        // A cap applied to bytes rather than grapheme clusters would leave a
        // partial cluster (a lone 👩 or a dangling zero-width joiner) at the
        // end; every character here must still be the whole family emoji.
        #expect(sanitized.allSatisfy { $0 == "👩‍👩‍👧‍👦" })
    }

    @Test("truncation does not leave a trailing space or dot")
    func truncationRetrims() {
        let long = String(repeating: "ab ", count: 100)
        let sanitized = FilenameSanitizer.sanitize(long)
        #expect(!sanitized.hasSuffix(" "))
        #expect(!sanitized.hasSuffix("."))
    }

    // MARK: - Collision suffixes

    @Test("a free name is returned unchanged")
    func freeNameIsUnchanged() {
        #expect(FilenameSanitizer.uniqueName(for: "Standup") { _ in false } == "Standup")
    }

    @Test("the first collision gets ' 2'")
    func firstCollisionGetsTwo() {
        let taken: Set<String> = ["Standup"]
        #expect(FilenameSanitizer.uniqueName(for: "Standup") { taken.contains($0) } == "Standup 2")
    }

    @Test("suffixes keep counting up past taken variants")
    func suffixesCountUp() {
        let taken: Set<String> = ["Standup", "Standup 2", "Standup 3"]
        #expect(FilenameSanitizer.uniqueName(for: "Standup") { taken.contains($0) } == "Standup 4")
    }

    @Test("a gap in the sequence is reused")
    func gapsAreReused() {
        let taken: Set<String> = ["Standup", "Standup 3"]
        #expect(FilenameSanitizer.uniqueName(for: "Standup") { taken.contains($0) } == "Standup 2")
    }

    @Test("double-digit and triple-digit suffixes work")
    func manyCollisions() {
        var taken: Set<String> = ["Standup"]
        for index in 2...150 { taken.insert("Standup \(index)") }
        #expect(FilenameSanitizer.uniqueName(for: "Standup") { taken.contains($0) } == "Standup 151")
    }

    @Test("a suffixed name still respects the length caps")
    func suffixedNamesRespectCaps() {
        let base = FilenameSanitizer.sanitize(String(repeating: "a", count: 500))
        let unique = FilenameSanitizer.uniqueName(for: base) { $0 == base }

        #expect(unique.hasSuffix(" 2"))
        #expect(unique.count <= FilenameSanitizer.maxCharacters)
        #expect(unique.utf8.count <= FilenameSanitizer.maxUTF8Bytes)
    }

    @Test("shortening for a suffix does not leave a double space")
    func suffixDoesNotDoubleSpace() {
        let base = String(repeating: "ab ", count: 60)              // 180 chars
        let sanitized = FilenameSanitizer.sanitize(base)
        let unique = FilenameSanitizer.uniqueName(for: sanitized) { $0 == sanitized }

        #expect(!unique.contains("  "))
        #expect(unique.hasSuffix(" 2"))
    }
}
