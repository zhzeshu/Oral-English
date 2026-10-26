import Foundation
import Testing

@Suite("MarkdownIntake")
struct MarkdownIntakeTests {

    /// The substring a style covers, so assertions read as words rather than offsets.
    private func covered(_ style: InlineStyle, in text: String) -> String? {
        SpokenRange.substring(in: text, utf16Location: style.location, utf16Length: style.length)
    }

    @Test("markup never reaches the text the voice reads")
    func markupIsStripped() {
        let r = SentenceSplitter.split("The **quick** brown *fox* jumps `over` the [lazy](https://x.y) ~~dog~~.")
        #expect(r.sentences.map(\.text) == ["The quick brown fox jumps over the lazy dog."])
    }

    @Test("inline styles land on the right words, sentence by sentence")
    func stylesFollowSentences() throws {
        let r = SentenceSplitter.split("One **bold** word. Then an *italic* one and a [link](https://x.y).")
        #expect(r.sentences.count == 2)

        let first = r.sentences[0]
        let firstStyles = try #require(first.styles)
        #expect(firstStyles.map(\.kind) == [.strong])
        #expect(covered(firstStyles[0], in: first.text) == "bold")

        let second = r.sentences[1]
        let secondStyles = try #require(second.styles)
        #expect(secondStyles.map(\.kind) == [.emphasis, .link])
        #expect(covered(secondStyles[0], in: second.text) == "italic")
        #expect(covered(secondStyles[1], in: second.text) == "link")
        #expect(secondStyles[1].url == "https://x.y")
    }

    @Test("a style spanning a sentence boundary is split between both sentences")
    func styleAcrossSentences() throws {
        let r = SentenceSplitter.split("**First one. Second one.**")
        #expect(r.sentences.count == 2)
        for s in r.sentences {
            let styles = try #require(s.styles)
            #expect(styles.count == 1)
            #expect(covered(styles[0], in: s.text) == s.text)
        }
    }

    @Test("the paragraph keeps the same styles over its whole text")
    func paragraphStyles() throws {
        let r = SentenceSplitter.split("A **b** c. D *e* f.")
        let p = try #require(r.paragraphs.first)
        let styles = try #require(p.styles)
        #expect(styles.compactMap { covered($0, in: p.text) } == ["b", "e"])
    }

    @Test("headings, list items and quotes are their own paragraphs with their block style")
    func blockStyles() {
        let md = """
        # The Title
        Some intro text.
        - First item.
        - Second item.
        1. Ordered.
        > A quote.
        """
        let r = SentenceSplitter.split(md)
        #expect(r.paragraphs.map(\.text) == [
            "The Title", "Some intro text.", "First item.", "Second item.", "Ordered.", "A quote.",
        ])
        #expect(r.paragraphs.map(\.block) == [
            BlockStyle(kind: .heading, level: 1),
            nil,
            BlockStyle(kind: .listItem, level: 1, marker: "•"),
            BlockStyle(kind: .listItem, level: 1, marker: "•"),
            BlockStyle(kind: .listItem, level: 1, marker: "1."),
            BlockStyle(kind: .quote),
        ])
    }

    @Test("an ordered list keeps the number as written, so a year at line start is not lost")
    func orderedListNumbers() {
        let r = SentenceSplitter.split("2020. A hard year.\n2021. A better one.")
        #expect(r.paragraphs.map(\.block?.marker) == ["2020.", "2021."])
    }

    @Test("nested list items carry their depth")
    func nestedList() {
        let r = SentenceSplitter.split("- Outer.\n  - Inner.")
        #expect(r.paragraphs.map(\.block?.level) == [1, 2])
    }

    @Test("a second paragraph in one list item is indented but unmarked")
    func looseListItem() {
        let r = SentenceSplitter.split("- First para.\n\n  Second para.\n- Next item.")
        #expect(r.paragraphs.map(\.block?.marker) == ["•", nil, "•"])
        #expect(r.paragraphs.map(\.block?.kind) == [.listItem, .listItem, .listItem])
    }

    @Test("a single newline survives as a newline, so a poem keeps its lines")
    func softBreakKept() {
        let r = SentenceSplitter.split("Roses are red,\nviolets are blue.")
        #expect(r.paragraphs.count == 1)
        #expect(r.paragraphs[0].text == "Roses are red,\nviolets are blue.")
    }

    @Test("indented prose is an ordinary paragraph, not a code block")
    func indentedProse() {
        let r = SentenceSplitter.split("    An indented first paragraph.\n\nThe next one.")
        #expect(r.paragraphs.map(\.text) == ["An indented first paragraph.", "The next one."])
        #expect(r.paragraphs.allSatisfy { $0.block == nil && $0.styles == nil })
    }

    @Test("inline HTML and thematic breaks produce no words")
    func htmlAndRules() {
        let r = SentenceSplitter.split("Use <b>bold</b> here.\n\n---\n\nAfter.")
        #expect(r.sentences.map(\.text) == ["Use bold here.", "After."])
    }

    @Test("a table row reads as one line of its cells")
    func tableRows() {
        let r = SentenceSplitter.split("| Word | Meaning |\n|---|---|\n| apple | a fruit |")
        #expect(r.paragraphs.map(\.text) == ["Word, Meaning", "apple, a fruit"])
    }

    @Test("plain prose carries no styles at all, so its JSON is unchanged")
    func plainProseUnstyled() throws {
        let r = SentenceSplitter.split("Just plain text. Nothing special.\n\nAnother paragraph.")
        #expect(r.sentences.allSatisfy { $0.styles == nil })
        #expect(r.paragraphs.allSatisfy { $0.styles == nil && $0.block == nil })
        let json = String(decoding: try JSONEncoder().encode(r.paragraphs), as: UTF8.self)
        #expect(!json.contains("styles") && !json.contains("block"))
    }

    @Test("styles stay aligned past accented characters and emoji")
    func utf16Offsets() throws {
        let r = SentenceSplitter.split("Café 🎉 is **très** good.")
        let s = try #require(r.sentences.first)
        let style = try #require(s.styles?.first)
        #expect(covered(style, in: s.text) == "très")
    }

    @Test("the whole passage places each paragraph's styles after the ones before it")
    func passageStyles() throws {
        let split = SentenceSplitter.split("First **one**.\n\nSecond *two*.")
        let passage = Passage(
            title: "t", createdAt: Date(), updatedAt: Date(), sourceText: "",
            paragraphs: split.paragraphs, sentences: split.sentences
        )
        let ref = TargetRef.passage(passage.id)
        let text = try #require(passage.text(for: ref))
        #expect(passage.styles(for: ref).compactMap { covered($0, in: text) } == ["one", "two"])
    }

    @Test("an opening heading is suggested as the title, and only an opening one")
    func suggestedTitle() {
        #expect(SentenceSplitter.split("# My Story\n\nOnce upon a time.").suggestedTitle == "My Story")
        #expect(SentenceSplitter.split("Once upon a time.\n\n# Later").suggestedTitle == nil)
        #expect(SentenceSplitter.split("Plain text.").suggestedTitle == nil)
    }

    @Test("a passage saved before markdown support still decodes")
    func legacyDecode() throws {
        let legacy = """
        {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","index":0,"paragraphIndex":0,"text":"Old."}
        """
        let s = try JSONDecoder().decode(Sentence.self, from: Data(legacy.utf8))
        #expect(s.text == "Old.")
        #expect(s.styles == nil)
    }
}
