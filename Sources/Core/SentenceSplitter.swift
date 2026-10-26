import Foundation
import NaturalLanguage

/// Splits pasted text into paragraphs and sentences.
public enum SentenceSplitter {

    public struct Result: Sendable, Equatable {
        public var paragraphs: [Paragraph]
        public var sentences: [Sentence]

        public init(paragraphs: [Paragraph], sentences: [Sentence]) {
            self.paragraphs = paragraphs
            self.sentences = sentences
        }

        /// A markdown document that opens with a heading has already named itself.
        public var suggestedTitle: String? {
            guard let first = paragraphs.first, first.block?.kind == .heading else { return nil }
            return first.text
        }
    }

    /// Paragraphs are markdown blocks; sentences are split with `NLTokenizer`.
    ///
    /// Plain prose is valid markdown, so for it a block is exactly what this used to split
    /// on: text between blank lines. There is deliberately **no fallback** to single-newline
    /// splitting. Revision 1 of the plan specified "split on blank lines, falling back to
    /// single newlines when that yields one chunk" and simultaneously required
    /// `"Line one.\nLine two."` to be one paragraph. Those cannot both hold: one chunk
    /// triggers the fallback and yields two. Normalizing line endings in `TextIntake` and
    /// splitting only on blank lines satisfies the requirement, and handles CRLF correctly as
    /// a side effect.
    ///
    /// The cost is that text using single newlines as paragraph breaks collapses to one
    /// paragraph. Sentences are still found correctly, so only paragraph-level practice is
    /// affected, and the paste sheet's live count makes it visible before committing. Markdown
    /// adds the exceptions markdown always has: a heading, a list item or a quote is its own
    /// paragraph even without a blank line around it.
    public static func split(_ rawText: String) -> Result {
        let text = TextIntake.clean(rawText)

        var paragraphs: [Paragraph] = []
        var sentences: [Sentence] = []
        var globalIndex = 0

        for block in MarkdownIntake.blocks(from: text) {
            let sentenceTexts = sentenceTexts(in: block.text)
            guard !sentenceTexts.isEmpty else { continue }

            // Each sentence takes its share of the block's styles, located the same way the
            // speech highlight locates it.
            let starts = SpokenRange.sentenceStarts(in: block.text, sentences: sentenceTexts)

            var ids: [UUID] = []
            for (t, start) in zip(sentenceTexts, starts) {
                let styles = InlineStyle.clip(block.styles, to: start, length: t.utf16.count)
                let s = Sentence(
                    index: globalIndex, paragraphIndex: paragraphs.count, text: t,
                    styles: styles.isEmpty ? nil : styles
                )
                sentences.append(s)
                ids.append(s.id)
                globalIndex += 1
            }
            paragraphs.append(
                Paragraph(
                    index: paragraphs.count, text: block.text, sentenceIDs: ids,
                    styles: block.styles.isEmpty ? nil : block.styles, block: block.style
                )
            )
        }

        return Result(paragraphs: paragraphs, sentences: sentences)
    }

    /// Sentences within one paragraph.
    ///
    /// `NLTokenizer` is a class and is not `Sendable`, so a fresh one is created per call and
    /// never stored. `setLanguage(.english)` is always set: auto-detection on a short string
    /// guesses wrong and splits badly.
    static func sentenceTexts(in paragraph: String) -> [String] {
        guard !paragraph.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.setLanguage(.english)
        tokenizer.string = paragraph

        var out: [String] = []
        tokenizer.enumerateTokens(in: paragraph.startIndex..<paragraph.endIndex) { range, _ in
            let piece = paragraph[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if piece.rangeOfCharacter(from: .alphanumerics) != nil {
                out.append(piece)
            }
            return true
        }
        return out
    }

    /// Word tokens, used by the normalizer and for display alignment.
    public static func words(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(.english)
        tokenizer.string = text
        var out: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            out.append(String(text[range]))
            return true
        }
        return out
    }
}
