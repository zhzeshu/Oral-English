import Foundation
import Testing

@Suite("SentenceSplitter")
struct SentenceSplitterTests {

    @Test("abbreviations do not split a sentence")
    func abbreviations() {
        let r = SentenceSplitter.split("This is Dr. Smith's test, e.g. one sentence!")
        #expect(r.sentences.count == 1)
        #expect(r.paragraphs.count == 1)
    }

    @Test("a time with periods does not split")
    func timeOfDay() {
        let r = SentenceSplitter.split("Then, at 4 p.m., it moved on.")
        #expect(r.sentences.count == 1)
    }

    @Test("three sentences, none carrying surrounding whitespace")
    func threeSentences() {
        let r = SentenceSplitter.split("One. Two. Three.")
        #expect(r.sentences.count == 3)
        for s in r.sentences {
            #expect(s.text == s.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    @Test("a blank line separates paragraphs")
    func blankLineParagraphs() {
        let r = SentenceSplitter.split("First para.\n\nSecond para.")
        #expect(r.paragraphs.count == 2)
        #expect(r.sentences.count == 2)
        #expect(r.paragraphs[0].sentenceIDs.count == 1)
        #expect(r.paragraphs[1].sentenceIDs.count == 1)
    }

    /// The row that revision 1's algorithm could not satisfy. A single newline is an
    /// intra-paragraph break, not a paragraph break.
    @Test("a single newline stays inside one paragraph")
    func singleNewlineIsOneParagraph() {
        let r = SentenceSplitter.split("Line one.\nLine two.")
        #expect(r.paragraphs.count == 1)
        #expect(r.sentences.count == 2)
    }

    @Test("CRLF blank lines separate paragraphs too")
    func crlfParagraphs() {
        let r = SentenceSplitter.split("First para.\r\n\r\nSecond para.")
        #expect(r.paragraphs.count == 2)
        #expect(r.sentences.count == 2)
    }

    @Test("CRLF single newline stays one paragraph")
    func crlfSingleNewline() {
        let r = SentenceSplitter.split("Line one.\r\nLine two.")
        #expect(r.paragraphs.count == 1)
        #expect(r.sentences.count == 2)
    }

    @Test("empty and whitespace-only input yields nothing and does not crash", arguments: ["", "   ", "\n\n\n", "\t"])
    func emptyInput(text: String) {
        let r = SentenceSplitter.split(text)
        #expect(r.paragraphs.isEmpty)
        #expect(r.sentences.isEmpty)
    }

    @Test("text with no terminal punctuation is still one sentence")
    func noTerminalPunctuation() {
        let r = SentenceSplitter.split("No terminal punctuation")
        #expect(r.sentences.count == 1)
    }

    @Test("punctuation-only input produces no sentences")
    func punctuationOnly() {
        let r = SentenceSplitter.split("... !!! ???")
        #expect(r.sentences.isEmpty)
    }

    @Test("indices are contiguous from zero and paragraphIndex is correct")
    func indicesAreCoherent() {
        let text = "A one. A two.\n\nB one.\n\nC one. C two. C three."
        let r = SentenceSplitter.split(text)
        #expect(r.paragraphs.count == 3)
        #expect(r.sentences.count == 6)
        for (i, s) in r.sentences.enumerated() {
            #expect(s.index == i)
        }
        #expect(r.sentences.map(\.paragraphIndex) == [0, 0, 1, 2, 2, 2])
        for (pi, p) in r.paragraphs.enumerated() {
            #expect(p.index == pi)
            let owned = r.sentences.filter { $0.paragraphIndex == pi }.map(\.id)
            #expect(p.sentenceIDs == owned)
        }
    }

    @Test("sentence ids are unique and stable within one split")
    func idsAreUnique() {
        let r = SentenceSplitter.split("One. Two. Three.")
        #expect(Set(r.sentences.map(\.id)).count == 3)
        #expect(Set(r.paragraphs.map(\.id)).count == 1)
    }

    @Test("NUL in the input does not inflate the sentence count")
    func nulDoesNotSplit() {
        let r = SentenceSplitter.split("One.\0Two.")
        #expect(r.sentences.count == 1)
        for s in r.sentences {
            #expect(!s.text.unicodeScalars.contains("\0"))
        }
    }

    @Test("a large paste completes quickly")
    func largePaste() {
        let sentence = "The quick brown fox jumps over the lazy dog. "
        let text = String(repeating: sentence, count: 2_000)
        let start = Date()
        let r = SentenceSplitter.split(text)
        let elapsed = Date().timeIntervalSince(start)
        #expect(r.sentences.count == 2_000)
        #expect(elapsed < 2.0, "splitting took \(elapsed)s")
    }

    @Test("word tokenizer handles abbreviations and contractions")
    func wordTokens() {
        let w = SentenceSplitter.words(in: "Don't stop at 4 p.m.")
        #expect(!w.isEmpty)
        #expect(w.contains { $0.lowercased().contains("don") })
    }
}
