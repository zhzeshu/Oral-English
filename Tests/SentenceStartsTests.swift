import Foundation
import Testing

/// Offsets that turn a sentence-local highlight range into a paragraph-local one.
///
/// The bug these cover: a paragraph row highlighted only inside its first sentence, for the
/// whole paragraph, because every utterance reports offsets from zero.
@Suite("SpokenRange.sentenceStarts")
struct SentenceStartsTests {

    @Test("the first sentence starts at zero and the rest follow in order")
    func simpleParagraph() {
        let a = "The fog came in."
        let b = "It sat looking."
        let text = "\(a) \(b)"
        let starts = SpokenRange.sentenceStarts(in: text, sentences: [a, b])
        #expect(starts == [0, (a + " ").utf16.count])
        // The offsets must actually slice their own sentence back out.
        #expect(SpokenRange.substring(in: text, utf16Location: starts[1], utf16Length: b.utf16.count) == b)
    }

    @Test("a repeated sentence resolves to the later occurrence, not the first again")
    func repeatedSentence() {
        let s = "It came."
        let text = "\(s) \(s)"
        let starts = SpokenRange.sentenceStarts(in: text, sentences: [s, s])
        #expect(starts[0] == 0)
        #expect(starts[1] == (s + " ").utf16.count)
        #expect(starts[0] != starts[1], "searching must advance, or both land on the first copy")
    }

    @Test("whatever whitespace the author typed between sentences is respected")
    func unusualSeparators() {
        let a = "First one."
        let b = "Second one."
        for separator in ["  ", "\n", "\n\n", "\t", " \n "] {
            let text = a + separator + b
            let starts = SpokenRange.sentenceStarts(in: text, sentences: [a, b])
            #expect(SpokenRange.substring(in: text, utf16Location: starts[1],
                                          utf16Length: b.utf16.count) == b,
                    "separator \(separator.debugDescription) misplaced the second sentence")
        }
    }

    @Test("paragraphs joined with a blank line, which is how a whole-passage target reads")
    func wholePassage() {
        let one = "Alpha one."
        let two = "Beta two."
        let three = "Gamma three."
        let text = "\(one) \(two)\n\n\(three)"
        let starts = SpokenRange.sentenceStarts(in: text, sentences: [one, two, three])
        #expect(starts.count == 3)
        for (i, sentence) in [one, two, three].enumerated() {
            #expect(SpokenRange.substring(in: text, utf16Location: starts[i],
                                          utf16Length: sentence.utf16.count) == sentence)
        }
    }

    @Test("offsets are UTF-16 units, so an emoji earlier in the text shifts what follows")
    func utf16NotCharacters() {
        let a = "Look 👀 here."
        let b = "Then read."
        let text = "\(a) \(b)"
        let starts = SpokenRange.sentenceStarts(in: text, sentences: [a, b])
        // The emoji is a surrogate pair: one Character, two UTF-16 units. A Character count
        // would be short by one and would slice mid-word.
        #expect(starts[1] == (a + " ").utf16.count)
        #expect(starts[1] != (a + " ").count)
        #expect(SpokenRange.substring(in: text, utf16Location: starts[1], utf16Length: b.utf16.count) == b)
    }

    @Test("a sentence that is not present does not desynchronize the ones after it")
    func missingSentence() {
        let a = "Present one."
        let b = "Present two."
        let text = "\(a) \(b)"
        let starts = SpokenRange.sentenceStarts(in: text, sentences: [a, "Not in the text.", b])
        #expect(starts.count == 3)
        #expect(starts[0] == 0)
        #expect(SpokenRange.substring(in: text, utf16Location: starts[2], utf16Length: b.utf16.count) == b,
                "the sentence after a missing one must still resolve correctly")
    }

    @Test("empty inputs are answered, not crashed on")
    func degenerate() {
        #expect(SpokenRange.sentenceStarts(in: "", sentences: []) == [])
        #expect(SpokenRange.sentenceStarts(in: "Some text.", sentences: []) == [])
        #expect(SpokenRange.sentenceStarts(in: "", sentences: ["anything"]) == [0])
        #expect(SpokenRange.sentenceStarts(in: "Some text.", sentences: [""]) == [0])
    }

    @Test("a single-sentence target is unchanged, which is the common case")
    func singleSentence() {
        let only = "Just the one."
        #expect(SpokenRange.sentenceStarts(in: only, sentences: [only]) == [0])
    }
}
