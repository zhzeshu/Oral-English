import Foundation

/// Turns pasted text into blocks of plain text with their formatting kept alongside.
///
/// Every paste goes through here, markdown or not, because plain prose is already valid
/// markdown and comes out unchanged: blank lines still separate paragraphs, and a single
/// newline still stays inside one, kept as a newline rather than folded into a space so a
/// poem keeps its lines.
///
/// The markup never reaches the text. What a block carries is the plain text the voice
/// reads and the scorer compares against, plus `InlineStyle` ranges over it and an optional
/// `BlockStyle`, so rows can draw bold, headings and bullets without the voice reading
/// asterisks aloud or the highlight drifting by the width of a `**`.
///
/// Parsing is Foundation's own (`AttributedString(markdown:)`, full syntax), so there is no
/// parser here to maintain -- only the mapping from its output to blocks.
public enum MarkdownIntake {

    public struct Block: Sendable, Equatable {
        public var text: String
        public var styles: [InlineStyle]
        public var style: BlockStyle?
    }

    public static func blocks(from cleaned: String) -> [Block] {
        guard let parsed = try? AttributedString(
            markdown: cleaned,
            options: .init(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        ) else {
            // Not expected -- the full-syntax parser accepts any string -- but the paste
            // must never be lost to it. Fall back to the text as one plain block.
            return [Block(text: cleaned, styles: [], style: nil)]
        }

        var out: [Block] = []
        var current: Builder?
        var lastListItem: Int?

        for run in parsed.runs {
            let intent = run.presentationIntent
            let key = blockIdentity(intent)
            if current?.key != key {
                if let done = current?.finish() { out.append(done) }
                let style = blockStyle(intent, lastListItem: &lastListItem)
                current = Builder(key: key, style: style, isTableRow: isTableCell(intent))
            }
            current?.append(run, characters: String(parsed[run.range].characters))
        }
        if let done = current?.finish() { out.append(done) }
        return out
    }

    // MARK: - Blocks

    /// Which block a run belongs to: its innermost block intent, except that table cells
    /// group by row, so a row is practiced as one line rather than one cell at a time.
    private static func blockIdentity(_ intent: PresentationIntent?) -> Int {
        guard let components = intent?.components, let innermost = components.first else { return -1 }
        if case .tableCell = innermost.kind, components.count > 1 {
            return components[1].identity
        }
        return innermost.identity
    }

    private static func isTableCell(_ intent: PresentationIntent?) -> Bool {
        if case .tableCell = intent?.components.first?.kind { return true }
        return false
    }

    /// The block's look. A code block is deliberately an ordinary paragraph: four spaces of
    /// indentation make one, so prose pasted from a PDF with indented paragraphs would
    /// otherwise turn up in a monospaced box.
    private static func blockStyle(_ intent: PresentationIntent?, lastListItem: inout Int?) -> BlockStyle? {
        guard let components = intent?.components else { return nil }

        let listItems = components.enumerated().compactMap { i, c -> (Int, Int, Int)? in
            if case .listItem(let ordinal) = c.kind { return (i, ordinal, c.identity) }
            return nil
        }
        if let (i, ordinal, identity) = listItems.first {
            var ordered = false
            if i + 1 < components.count, case .orderedList = components[i + 1].kind { ordered = true }
            // A second paragraph in the same item is indented like the first but unmarked.
            let marker = identity == lastListItem ? nil : (ordered ? "\(ordinal)." : "•")
            lastListItem = identity
            return BlockStyle(kind: .listItem, level: listItems.count, marker: marker)
        }
        lastListItem = nil

        for c in components {
            if case .header(let level) = c.kind { return BlockStyle(kind: .heading, level: level) }
        }
        for c in components {
            if case .blockQuote = c.kind { return BlockStyle(kind: .quote) }
        }
        return nil
    }

    // MARK: - Building one block

    private struct Builder {
        let key: Int
        let style: BlockStyle?
        let isTableRow: Bool
        var text = ""
        var utf16Count = 0
        var styles: [InlineStyle] = []
        var lastCell: Int?

        init(key: Int, style: BlockStyle?, isTableRow: Bool) {
            self.key = key
            self.style = style
            self.isTableRow = isTableRow
        }

        mutating func append(_ run: AttributedString.Runs.Run, characters: String) {
            let inline = run.inlinePresentationIntent ?? []

            // Raw HTML is markup, not words.
            if inline.contains(.inlineHTML) || inline.contains(.blockHTML) { return }

            // Cells of one row read as a list of items.
            if isTableRow, let cell = run.presentationIntent?.components.first?.identity {
                if let last = lastCell, last != cell { add(", ") }
                lastCell = cell
            }

            if inline.contains(.softBreak) || inline.contains(.lineBreak) {
                add("\n")
                return
            }

            let start = utf16Count
            add(characters)
            let length = utf16Count - start
            guard length > 0 else { return }

            if inline.contains(.stronglyEmphasized) { styles.append(.init(kind: .strong, location: start, length: length)) }
            if inline.contains(.emphasized) { styles.append(.init(kind: .emphasis, location: start, length: length)) }
            if inline.contains(.code) { styles.append(.init(kind: .code, location: start, length: length)) }
            if inline.contains(.strikethrough) { styles.append(.init(kind: .strikethrough, location: start, length: length)) }
            if let url = run.link {
                styles.append(.init(kind: .link, location: start, length: length, url: url.absoluteString))
            }
        }

        private mutating func add(_ s: String) {
            text += s
            utf16Count += s.utf16.count
        }

        /// Trimmed, with styles rebased onto the trimmed text. Nil when nothing is left,
        /// which is how a thematic break or an HTML-only block disappears.
        func finish() -> Block? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let lower = text.range(of: trimmed) else { return nil }
            let lead = text.utf16.distance(from: text.startIndex, to: lower.lowerBound)
            let kept = InlineStyle.clip(styles, to: lead, length: trimmed.utf16.count)
            return Block(text: trimmed, styles: kept, style: style)
        }
    }
}
