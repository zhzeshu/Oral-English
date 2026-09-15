import Foundation
import Testing

@Suite("Normalizer")
struct NormalizerTests {

    func norm(_ s: String, _ side: Normalizer.Side = .reference) -> [String] {
        Normalizer.tokenize(s, side: side).map(\.normalized)
    }

    @Test("case is folded")
    func lowercases() {
        #expect(norm("The Fog") == ["the", "fog"])
    }

    @Test("whitelisted contractions expand")
    func expandsContractions() {
        #expect(norm("don't") == ["do", "not"])
        #expect(norm("I'm") == ["i", "am"])
        #expect(norm("let's") == ["let", "us"])
        #expect(norm("can't") == ["can", "not"])
    }

    @Test("an expanded contraction keeps one source index, so the UI highlights one word")
    func contractionSourceIndex() {
        let t = Normalizer.tokenize("don't stop")
        #expect(t.count == 3)
        #expect(t[0].sourceIndex == t[1].sourceIndex)
        #expect(t[2].sourceIndex != t[0].sourceIndex)
    }

    @Test("an ambiguous possessive is not expanded")
    func ambiguousPossessive() {
        let t = norm("Sandburg's")
        #expect(t.count == 1)
        #expect(t[0] == "sandburg's" || t[0] == "sandburgs", "got \(t)")
    }

    @Test("hyphenated words split, because recognizers emit them separately")
    func splitsHyphens() {
        #expect(norm("well-known") == ["well", "known"])
    }

    @Test("abbreviation dots are removed")
    func abbreviationDots() {
        let t = norm("at 4 p.m.")
        #expect(t.contains("pm"), "got \(t)")
        #expect(!t.contains("p.m."))
    }

    @Test("a digit accepts both its numeric and spelled forms")
    func digitAlternates() {
        let t = Normalizer.tokenize("3")
        #expect(t.count == 1)
        #expect(t[0].forms.contains("three"), "got \(t[0].forms)")
        #expect(t[0].forms.contains("3"))
    }

    @Test("an ordinal accepts its word form")
    func ordinalAlternates() {
        let t = Normalizer.tokenize("3rd")
        #expect(t.count == 1)
        #expect(t[0].forms.contains("third"), "got \(t[0].forms)")
    }

    @Test("a percentage contributes the word percent")
    func percentAlternate() {
        let t = Normalizer.tokenize("50%")
        #expect(t.contains { $0.forms.contains("percent") }, "got \(t.map(\.forms))")
    }

    @Test("larger numbers spell out")
    func largerNumbers() {
        let t = Normalizer.tokenize("1999")
        #expect(t[0].forms.contains("one") || t[0].forms.contains("nineteen"), "got \(t[0].forms)")
    }

    @Test("fillers drop from the hypothesis")
    func fillersDropFromHypothesis() {
        #expect(norm("um, the fog", .hypothesis) == ["the", "fog"])
        #expect(norm("uh the uh fog", .hypothesis) == ["the", "fog"])
    }

    /// One-sided by design: a reference that genuinely contains "um" keeps it.
    @Test("fillers are kept in the reference")
    func fillersKeptInReference() {
        #expect(norm("um, the fog", .reference) == ["um", "the", "fog"])
    }

    @Test("curly quotes and accents fold")
    func foldsQuotesAndAccents() {
        #expect(norm("don\u{2019}t") == ["do", "not"])
        let t = norm("café")
        #expect(t == ["cafe"], "got \(t)")
    }

    @Test("a repeated word is kept, not collapsed")
    func repeatedWordsKept() {
        #expect(norm("The the fog") == ["the", "the", "fog"])
    }

    @Test("punctuation-only and empty input produce no tokens", arguments: ["", "   ", "...", "!!!", "-"])
    func emptyish(text: String) {
        #expect(Normalizer.tokenize(text).isEmpty, "got \(norm(text))")
    }

    // MARK: - Similarity

    @Test("similarity is the normalized Levenshtein ratio")
    func similarityMetric() {
        #expect(Normalizer.similarity("feet", "feet") == 1.0)
        #expect(Normalizer.similarity("feet", "feed") == 0.75)
        #expect(Normalizer.similarity("", "abc") == 0.0)
        #expect(Normalizer.similarity("abc", "") == 0.0)
        #expect(Normalizer.similarity("", "") == 1.0)
    }

    @Test("feet and feed clear the partial threshold, so the table row is derivable")
    func feetFeedIsPartial() {
        let sim = Normalizer.similarity("feet", "feed")
        #expect(sim >= Normalizer.partialMatchThreshold)
        #expect(sim < 1.0)
    }

    @Test("unrelated words fall below the partial threshold")
    func unrelatedBelowThreshold() {
        #expect(Normalizer.similarity("harbor", "sitting") < Normalizer.partialMatchThreshold)
        #expect(Normalizer.similarity("in", "on") < 1.0)
    }

    /// Taking the maximum over alternates is what stops an alternate being worse than no
    /// alternate at all.
    @Test("token similarity takes the best over both sides' alternates")
    func alternateSimilarity() {
        let digit = Normalizer.tokenize("3")[0]
        let word = Normalizer.tokenize("three")[0]
        #expect(Normalizer.similarity(digit, word) == 1.0)
    }

    @Test("a near match against an alternate still scores as near")
    func alternateNearMatch() {
        let digit = Normalizer.tokenize("3")[0]
        let typo = Normalizer.Token(display: "thre", normalized: "thre", sourceIndex: 0)
        let sim = Normalizer.similarity(digit, typo)
        #expect(sim >= Normalizer.partialMatchThreshold, "got \(sim)")
        #expect(sim < 1.0)
    }

    @Test("similarity is symmetric and bounded", arguments: [
        ("harbor", "harbour"), ("feet", "feed"), ("a", "b"), ("hello", ""), ("", ""),
    ] as [(String, String)])
    func similarityProperties(a: String, b: String) {
        let ab = Normalizer.similarity(a, b)
        let ba = Normalizer.similarity(b, a)
        #expect(abs(ab - ba) < 1e-12)
        #expect(ab >= 0.0 && ab <= 1.0)
        #expect(ab.isFinite)
    }
}
