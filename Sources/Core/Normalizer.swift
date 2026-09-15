import Foundation
import NaturalLanguage

/// Turns a reference sentence or a recognizer transcript into comparable tokens.
///
/// Reference and transcript go through one identical pipeline, except where a rule is
/// explicitly one-sided (filler removal).
public enum Normalizer {

    /// One comparable token.
    public struct Token: Sendable, Equatable {
        /// Surface form for display, including trailing punctuation.
        public var display: String
        /// The form used for comparison.
        public var normalized: String
        /// Other spellings that should count as an exact match. A digit carries both its
        /// numeric and spelled forms, because which one the recognizer emits is arbitrary
        /// and a score must not depend on it.
        public var alternates: Set<String>
        /// Index of the display word this token came from. An expanded contraction produces
        /// two tokens sharing one source index, so the UI still highlights one word.
        public var sourceIndex: Int

        public init(display: String, normalized: String, alternates: Set<String> = [], sourceIndex: Int) {
            self.display = display
            self.normalized = normalized
            self.alternates = alternates
            self.sourceIndex = sourceIndex
        }

        /// All acceptable spellings of this token.
        public var forms: Set<String> { alternates.union([normalized]) }
    }

    // MARK: - Tunable constants
    //
    // Named here rather than left inline, because item 11 calibrates exactly these against
    // real recordings and nothing else. Revision 1 of the plan specified "similarity at or
    // above 0.72" without saying similarity of what, which made the constant meaningless.

    /// Two tokens count as a near match at or above this similarity. The metric is
    /// `similarity(_:_:)` below: normalized Levenshtein ratio over Characters.
    public static let partialMatchThreshold = 0.72

    /// Below this mean recognizer confidence, audio quality is in question.
    public static let lowConfidenceThreshold = 0.30

    /// Below this accuracy, combined with low confidence, present as hard to hear rather
    /// than as a bad score.
    public static let lowAccuracyThreshold = 0.50

    /// Contractions expanded because the recognizer reliably writes them out. Deliberately
    /// excludes ambiguous `'s` (possessive versus "is") and `'d` ("had" versus "would"),
    /// which keep one token with the apostrophe stripped and rely on partial credit.
    public static let contractions: [String: [String]] = [
        "don't": ["do", "not"], "doesn't": ["does", "not"], "didn't": ["did", "not"],
        "isn't": ["is", "not"], "aren't": ["are", "not"], "wasn't": ["was", "not"],
        "weren't": ["were", "not"], "haven't": ["have", "not"], "hasn't": ["has", "not"],
        "hadn't": ["had", "not"], "won't": ["will", "not"], "wouldn't": ["would", "not"],
        "can't": ["can", "not"], "cannot": ["can", "not"], "couldn't": ["could", "not"],
        "shouldn't": ["should", "not"], "mustn't": ["must", "not"], "needn't": ["need", "not"],
        "i'm": ["i", "am"], "i've": ["i", "have"], "i'll": ["i", "will"],
        "you're": ["you", "are"], "you've": ["you", "have"], "you'll": ["you", "will"],
        "we're": ["we", "are"], "we've": ["we", "have"], "we'll": ["we", "will"],
        "they're": ["they", "are"], "they've": ["they", "have"], "they'll": ["they", "will"],
        "he'll": ["he", "will"], "she'll": ["she", "will"], "it'll": ["it", "will"],
        "that's": ["that", "is"], "there's": ["there", "is"], "here's": ["here", "is"],
        "what's": ["what", "is"], "who's": ["who", "is"], "let's": ["let", "us"],
        "aren`t": ["are", "not"],
    ]

    /// Dropped from the hypothesis only. A reference that genuinely contains "um" keeps it.
    public static let fillers: Set<String> = [
        "uh", "uhh", "uhm", "um", "umm", "er", "err", "erm", "hmm", "hm", "mhm", "ah", "eh",
    ]

    /// Symbols the recognizer spells out.
    static let symbolWords: [Character: String] = [
        "%": "percent", "$": "dollars", "&": "and", "+": "plus", "=": "equals",
        "@": "at", "#": "number",
    ]

    // MARK: - Tokenizing

    public enum Side: Sendable {
        case reference
        case hypothesis
    }

    /// The full pipeline.
    public static func tokenize(_ text: String, side: Side = .reference) -> [Token] {
        let cleaned = expandSymbolsInText(collapseAbbreviations(fold(TextIntake.clean(text))))
        let words = SentenceSplitter.words(in: cleaned)

        var out: [Token] = []
        for (sourceIndex, rawWord) in words.enumerated() {
            let display = rawWord
            let lowered = rawWord.lowercased(with: Locale(identifier: "en_US"))

            // Contractions expand into two tokens sharing one source index.
            if let expansion = contractions[lowered] ?? contractions[stripApostrophes(lowered)] {
                for part in expansion {
                    out.append(Token(display: display, normalized: part, sourceIndex: sourceIndex))
                }
                continue
            }

            for piece in splitHyphens(lowered) {
                let stripped = stripPunctuation(piece)
                guard !stripped.isEmpty else { continue }

                if side == .hypothesis && fillers.contains(stripped) { continue }

                var alternates = Set<String>()
                if let spelled = spellOutNumber(stripped) {
                    // Keep both forms acceptable.
                    alternates.formUnion(spelled)
                }

                out.append(Token(
                    display: display,
                    normalized: stripped,
                    alternates: alternates,
                    sourceIndex: sourceIndex
                ))
            }
        }
        return out
    }

    // MARK: - Pipeline steps

    /// Unicode fold: compose, normalize quotes and dashes, strip diacritics.
    ///
    /// Diacritic folding has to happen here rather than being left to punctuation
    /// stripping, because `é` is a letter and survives that step untouched — which made
    /// `café` and `cafe` compare as different words.
    static func fold(_ s: String) -> String {
        var out = s.precomposedStringWithCanonicalMapping
        for (from, to) in [("\u{2019}", "'"), ("\u{2018}", "'"), ("\u{201C}", "\""), ("\u{201D}", "\""),
                           ("\u{2013}", " "), ("\u{2014}", " "), ("\u{2026}", " ")] {
            out = out.replacingOccurrences(of: from, with: to)
        }
        return out.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US"))
    }

    /// Joins dotted abbreviations into one word before tokenizing.
    ///
    /// `NLTokenizer(unit: .word)` splits `p.m.` into `p` and `m`, so the plan's expectation
    /// that abbreviation dots vanish into `pm` could not hold without this step.
    ///
    /// A run of two or more letter-then-dot pairs collapses to its letters, which leaves a
    /// single abbreviation such as `Dr.` untouched — that one becomes `dr` through ordinary
    /// punctuation stripping. Done as a scan rather than a regex because a lookbehind on a
    /// word boundary did not match here.
    static func collapseAbbreviations(_ s: String) -> String {
        let chars = Array(s)
        var out = ""
        var i = 0
        while i < chars.count {
            var j = i
            var letters = ""
            while j + 1 < chars.count, chars[j].isLetter, chars[j + 1] == "." {
                letters.append(chars[j])
                j += 2
            }
            if letters.count >= 2 {
                out += letters
                i = j
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        return out
    }

    /// Expands symbols into words on **both** sides, symmetrically.
    ///
    /// This replaces the alternates approach for symbols. The word tokenizer discards `%`
    /// before an alternates-based rule could ever see it, and there is no competing numeric
    /// spelling to preserve — the recognizer writes either `50%` or `50 percent`, and
    /// expanding both to the same tokens makes them match.
    static func expandSymbolsInText(_ s: String) -> String {
        var out = ""
        for ch in s {
            if let word = symbolWords[ch] {
                out.append(" ")
                out.append(word)
                out.append(" ")
            } else {
                out.append(ch)
            }
        }
        return out
    }

    /// `well-known` becomes two tokens, because recognizers emit separate words.
    static func splitHyphens(_ s: String) -> [String] {
        let parts = s.split(whereSeparator: { $0 == "-" || $0 == "\u{2010}" }).map(String.init)
        return parts.isEmpty ? [s] : parts
    }

    /// Removes punctuation but keeps intra-word apostrophes, so abbreviation dots vanish
    /// (`p.m.` becomes `pm`) while `sandburg's` stays one token.
    static func stripPunctuation(_ s: String) -> String {
        var out = ""
        for ch in s {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
            } else if ch == "'" {
                // Keep only between letters.
                if !out.isEmpty, let last = out.last, last.isLetter { out.append(ch) }
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
    }

    static func stripApostrophes(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "")
    }

    /// Spelled-out forms for a numeric token, as alternates.
    public static func spellOutNumber(_ token: String) -> Set<String>? {
        let bare = token.replacingOccurrences(of: ",", with: "")
        guard !bare.isEmpty else { return nil }

        // Ordinals: 1st, 2nd, 3rd, 4th...
        let ordinalSuffixes = ["st", "nd", "rd", "th"]
        for suffix in ordinalSuffixes where bare.hasSuffix(suffix) {
            let digits = String(bare.dropLast(suffix.count))
            if let n = Int(digits) {
                let f = NumberFormatter()
                f.locale = Locale(identifier: "en_US")
                f.numberStyle = .ordinal
                let ordinalStyle = NumberFormatter()
                ordinalStyle.locale = Locale(identifier: "en_US")
                ordinalStyle.numberStyle = .spellOut
                ordinalStyle.formattingContext = .standalone
                if let words = ordinalStyle.string(from: NSNumber(value: n)) {
                    // "three" -> "third" is not derivable from spellOut, so use the
                    // ordinal-word formatter when available.
                    var set = Set(splitWords(words))
                    let ordWords = NumberFormatter()
                    ordWords.locale = Locale(identifier: "en_US")
                    ordWords.numberStyle = .spellOut
                    if let ord = ordinalWord(for: n) { set.formUnion(splitWords(ord)) }
                    set.insert(bare)
                    return set
                }
            }
        }

        guard let n = Int(bare) else { return nil }
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .spellOut
        guard let words = f.string(from: NSNumber(value: n)) else { return nil }
        var set = Set(splitWords(words))
        set.insert(bare)
        return set
    }

    /// `3` -> `third`. NumberFormatter's `.ordinal` style gives "3rd", not "third", so the
    /// common cases are listed and the rest fall back to the cardinal plus "th".
    static func ordinalWord(for n: Int) -> String? {
        let known: [Int: String] = [
            1: "first", 2: "second", 3: "third", 4: "fourth", 5: "fifth",
            6: "sixth", 7: "seventh", 8: "eighth", 9: "ninth", 10: "tenth",
            11: "eleventh", 12: "twelfth", 20: "twentieth", 30: "thirtieth",
            40: "fortieth", 50: "fiftieth", 100: "hundredth", 1000: "thousandth",
        ]
        if let k = known[n] { return k }
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .spellOut
        guard let cardinal = f.string(from: NSNumber(value: n)) else { return nil }
        return cardinal + "th"
    }

    static func splitWords(_ s: String) -> [String] {
        s.lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "-" })
            .map(String.init)
    }

    /// `50%` contributes `percent`.
    static func expandSymbols(_ piece: String) -> Set<String>? {
        var found = Set<String>()
        for ch in piece {
            if let w = symbolWords[ch] { found.insert(w) }
        }
        return found.isEmpty ? nil : found
    }

    // MARK: - Similarity

    /// Normalized Levenshtein ratio over Characters: `1 - distance / max(count)`.
    ///
    /// This is *the* similarity metric referenced by `partialMatchThreshold`. Naming it
    /// matters: Jaro-Winkler, Dice and normalized edit distance all give different answers,
    /// so an unnamed metric makes the threshold and every partial-match expectation
    /// underivable.
    public static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1.0 }
        if a.isEmpty || b.isEmpty { return 0.0 }
        let d = editDistance(Array(a), Array(b))
        let longest = max(a.count, b.count)
        return 1.0 - Double(d) / Double(longest)
    }

    /// Similarity between two tokens, taking the best over both sides' alternates.
    ///
    /// Revision 1 said "exact or alternate match" and never said how a *near* match
    /// interacts with a multi-valued token. Taking the maximum is the only answer that
    /// keeps an alternate from being worse than no alternate at all.
    public static func similarity(_ a: Token, _ b: Token) -> Double {
        var best = 0.0
        for x in a.forms {
            for y in b.forms {
                if x == y { return 1.0 }
                best = max(best, similarity(x, y))
            }
        }
        return best
    }

    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}
