import Foundation
import Testing

@Suite("TextIntake")
struct TextIntakeTests {

    @Test("NUL is stripped rather than surviving into storage")
    func stripsNUL() {
        let cleaned = TextIntake.clean("One.\0Two.")
        #expect(!cleaned.unicodeScalars.contains("\0"))
        #expect(cleaned == "One.Two.")
    }

    @Test("other control characters are stripped")
    func stripsControlCharacters() {
        let cleaned = TextIntake.clean("One.\u{07}Two.\u{1B}Three.")
        #expect(cleaned == "One.Two.Three.")
    }

    @Test("newline and tab survive, because they are the only ones that mean anything")
    func keepsNewlineAndTab() {
        let cleaned = TextIntake.clean("a\nb\tc")
        #expect(cleaned == "a\nb\tc")
    }

    @Test("line endings normalize to LF", arguments: [
        ("a\r\nb", "a\nb"),
        ("a\rb", "a\nb"),
        ("a\r\n\r\nb", "a\n\nb"),
        ("a\nb", "a\nb"),
    ])
    func normalizesLineEndings(input: String, expected: String) {
        #expect(TextIntake.clean(input) == expected)
    }

    /// `CharacterSet.controlCharacters` covers Unicode format characters (category Cf), not
    /// only the C0 controls. Verified: U+200B and U+200E are members, U+00A0 is not. So
    /// invisible formatting characters are stripped too, which is what we want — a
    /// zero-width space inside a word would silently break word matching and produce a
    /// baffling diff, and no such character means anything in spoken English.
    @Test("invisible format characters are stripped", arguments: [
        "\u{200B}",  // zero-width space
        "\u{200E}",  // left-to-right mark
        "\u{FEFF}",  // byte-order mark
    ])
    func stripsFormatCharacters(invisible: String) {
        let cleaned = TextIntake.clean("One.\(invisible)Two.")
        #expect(cleaned == "One.Two.")
    }

    @Test("a non-breaking space survives, because it is a real space")
    func keepsNonBreakingSpace() {
        let cleaned = TextIntake.clean("One\u{00A0}Two")
        #expect(cleaned.unicodeScalars.contains("\u{00A0}"))
    }

    @Test("text is composed so JSON and a filename agree on composition")
    func composesUnicode() {
        // "e" followed by combining acute accent composes to a single scalar.
        let decomposed = "cafe\u{0301}"
        let cleaned = TextIntake.clean(decomposed)
        #expect(cleaned == "café")
        #expect(cleaned.unicodeScalars.count == 4)
    }

    @Test("emptiness detection", arguments: [
        ("", true), ("   ", true), ("\n\n\t", true), ("\0", true), ("a", false),
    ])
    func detectsEmptiness(input: String, expected: Bool) {
        #expect(TextIntake.isEffectivelyEmpty(input) == expected)
    }

    @Test("Latin letter detection drives the soft non-English hint", arguments: [
        ("Hello", true), ("中文标题", false), ("???", false), ("3 apples", true), ("123", false),
    ])
    func detectsLatinLetters(input: String, expected: Bool) {
        #expect(TextIntake.hasLatinLetters(input) == expected)
    }
}
