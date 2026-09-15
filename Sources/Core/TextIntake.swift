import Foundation

/// Sanitizes pasted text once, before anything else sees it.
///
/// This step did not exist in revision 1 of the plan, and its absence was a real defect: a
/// NUL character survives `NLTokenizer`, round-trips through JSON faithfully, and then
/// silently collapses any file URL containing it to the empty string. `appendingPathComponent`
/// neither throws nor sanitizes, so the failure would have surfaced as an empty `audioPath`
/// and been misdiagnosed as the absolute-path bug the export item warns about.
public enum TextIntake {

    /// Normalize line endings, strip meaningless control characters, and compose Unicode.
    ///
    /// Only `\n` and `\t` are kept, because no other control character means anything in an
    /// English pronunciation trainer. Stripping is lossy in principle and harmless in fact.
    public static func clean(_ raw: String) -> String {
        // CRLF and lone CR first. Doing this before paragraph splitting is what makes
        // Windows-pasted text behave, since "\r\n\r\n" contains no "\n\n" substring.
        var s = raw.replacingOccurrences(of: "\r\n", with: "\n")
        s = s.replacingOccurrences(of: "\r", with: "\n")

        // Strip control characters except newline and tab.
        //
        // Note that `CharacterSet.controlCharacters` also covers Unicode *format*
        // characters (category Cf): U+200B zero-width space, U+200E left-to-right mark and
        // U+FEFF are all members, while U+00A0 non-breaking space is not. Verified by
        // probe. Removing them is intentional — an invisible character inside a word would
        // silently break word matching and produce a diff nobody could explain.
        s = String(s.unicodeScalars.filter { scalar in
            if scalar == "\n" || scalar == "\t" { return true }
            return !CharacterSet.controlCharacters.contains(scalar)
        })

        // Compose, so the JSON text and an APFS filename derived from it agree.
        return s.precomposedStringWithCanonicalMapping
    }

    /// True when the text contains nothing worth practicing.
    public static func isEffectivelyEmpty(_ text: String) -> Bool {
        clean(text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// True when the text contains at least one Latin letter. Used to refuse to score text
    /// that has no scorable content, and to drive the soft non-English hint in the paste
    /// sheet. A hint, never a block: language detection on short text is unreliable, and a
    /// false block is worse than the bug it prevents.
    public static func hasLatinLetters(_ text: String) -> Bool {
        text.unicodeScalars.contains { s in
            (s.value >= 0x41 && s.value <= 0x5A) || (s.value >= 0x61 && s.value <= 0x7A)
        }
    }
}
