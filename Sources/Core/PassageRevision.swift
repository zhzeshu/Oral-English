import Foundation

/// The result of revising a passage's text: the new structure, with ids carried over.
///
/// Takes are linked to sentences and paragraphs by stable id, so a naive re-split would
/// mint fresh ids and detach every recording. Instead each new sentence inherits the id of
/// the old sentence it came from, matched in three passes:
///
/// 1. **Unchanged.** The longest in-order run of sentences whose text is identical.
/// 2. **Edited.** Within each gap between unchanged sentences, old and new sentences are
///    paired in order when at least `editSimilarityThreshold` of their words agree. A typo
///    fix keeps its takes; a rewrite does not.
/// 3. **Moved.** Any leftover new sentence identical to a leftover old one, wherever it is.
///
/// A paragraph inherits the id of the old paragraph that contributed most of its
/// sentences, each old id used at most once. The whole-passage id never changes.
///
/// An edited sentence keeps its takes, and each take still carries the `referenceText` it
/// was scored against, so its score stays honest. `LoadedPassage.bestTake` counts only
/// takes recorded against the current wording.
public struct PassageRevision: Sendable, Equatable {
    public var sourceText: String
    public var paragraphs: [Paragraph]
    public var sentences: [Sentence]
    /// Old ids kept by a sentence whose text changed.
    public var editedSentenceIDs: [UUID]
    /// Fresh ids, in reading order.
    public var addedSentenceIDs: [UUID]
    /// Old ids no new sentence inherited, in their old reading order.
    public var removedSentenceIDs: [UUID]
    public var removedParagraphIDs: [UUID]
    /// False when the cleaned text is exactly what the passage already holds.
    public var hasChanges: Bool

    /// Share of words two sentences must have in common, by word-level edit distance, for
    /// the new one to count as an edit of the old one. At 0.5 a sentence split in half
    /// keeps its id on the first half, and a sentence rewritten from scratch does not.
    public static let editSimilarityThreshold = 0.5

    public init(from old: Passage, to newText: String) {
        let split = SentenceSplitter.split(newText)
        let oldTexts = old.sentences.map(\.text)
        let newTexts = split.sentences.map(\.text)
        let oldIndexFor = Self.matchSentences(old: oldTexts, new: newTexts)

        // Sentences: inherit a matched id, or keep the fresh one the splitter minted.
        var finalID: [UUID: UUID] = [:]
        var sentences: [Sentence] = []
        var edited: [UUID] = []
        var added: [UUID] = []
        for (j, fresh) in split.sentences.enumerated() {
            var s = fresh
            if let i = oldIndexFor[j] {
                s.id = old.sentences[i].id
                if oldTexts[i] != newTexts[j] { edited.append(s.id) }
            } else {
                added.append(s.id)
            }
            finalID[fresh.id] = s.id
            sentences.append(s)
        }
        let usedOld = Set(oldIndexFor.values)
        let removed = old.sentences.indices.filter { !usedOld.contains($0) }.map { old.sentences[$0].id }

        // Paragraphs: inherit from the old paragraph contributing the most sentences.
        var oldParagraphOf: [UUID: Int] = [:]
        for (k, p) in old.paragraphs.enumerated() {
            for id in p.sentenceIDs { oldParagraphOf[id] = k }
        }
        var usedParagraphs = Set<Int>()
        var paragraphs: [Paragraph] = []
        for fresh in split.paragraphs {
            var p = fresh
            p.sentenceIDs = fresh.sentenceIDs.map { finalID[$0] ?? $0 }
            var counts: [Int: Int] = [:]
            for id in p.sentenceIDs {
                if let k = oldParagraphOf[id], !usedParagraphs.contains(k) { counts[k, default: 0] += 1 }
            }
            // Highest count, then the earliest paragraph, so the choice is deterministic.
            if let best = counts.max(by: { ($0.value, -$0.key) < ($1.value, -$1.key) })?.key {
                usedParagraphs.insert(best)
                p.id = old.paragraphs[best].id
            }
            paragraphs.append(p)
        }
        let removedParagraphs = old.paragraphs.indices
            .filter { !usedParagraphs.contains($0) }
            .map { old.paragraphs[$0].id }

        let cleaned = TextIntake.clean(newText)
        self.sourceText = cleaned
        self.paragraphs = paragraphs
        self.sentences = sentences
        self.editedSentenceIDs = edited
        self.addedSentenceIDs = added
        self.removedSentenceIDs = removed
        self.removedParagraphIDs = removedParagraphs
        self.hasChanges = cleaned != old.sourceText
    }

    /// `passage` with this revision's text and structure. Identity, title, theme and
    /// creation date are untouched.
    public func applied(to passage: Passage, at date: Date) -> Passage {
        var p = passage
        p.sourceText = sourceText
        p.paragraphs = paragraphs
        p.sentences = sentences
        p.updatedAt = date.wholeSecond
        return p
    }

    /// The takes this revision would hide: those on a sentence or paragraph it removes.
    /// Takes already orphaned by an earlier revision are not counted again.
    public func orphanedTakes(_ takes: [Take]) -> [Take] {
        let sentences = Set(removedSentenceIDs)
        let paragraphs = Set(removedParagraphIDs)
        return takes.filter { take in
            switch take.target.kind {
            case .sentence: return sentences.contains(take.target.id)
            case .paragraph: return paragraphs.contains(take.target.id)
            case .passage: return false
            }
        }
    }

    // MARK: - Matching

    /// Maps each new sentence index to the old sentence index it inherits from.
    static func matchSentences(old: [String], new: [String]) -> [Int: Int] {
        var result: [Int: Int] = [:]

        // 1. Unchanged: longest common subsequence on exact text.
        let anchors = longestCommonSubsequence(old, new)
        for (i, j) in anchors { result[j] = i }

        // 2. Edited: weighted alignment inside each gap between anchors.
        let oldWords = old.map(words)
        let newWords = new.map(words)
        var previous = (-1, -1)
        for anchor in anchors + [(old.count, new.count)] {
            let oldGap = Array((previous.0 + 1)..<anchor.0)
            let newGap = Array((previous.1 + 1)..<anchor.1)
            if !oldGap.isEmpty && !newGap.isEmpty {
                for (a, b) in alignBySimilarity(oldGap, newGap, oldWords, newWords) {
                    result[b] = a
                }
            }
            previous = anchor
        }

        // 3. Moved: leftover exact matches, regardless of order.
        var usedOld = Set(result.values)
        for j in new.indices where result[j] == nil {
            if let i = old.indices.first(where: { !usedOld.contains($0) && old[$0] == new[j] }) {
                result[j] = i
                usedOld.insert(i)
            }
        }
        return result
    }

    static func longestCommonSubsequence(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return [] }
        // lengths[i][j] is the LCS length of a[i...] and b[j...].
        var lengths = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lengths[i][j] = a[i] == b[j]
                    ? lengths[i + 1][j + 1] + 1
                    : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }
        var out: [(Int, Int)] = []
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] {
                out.append((i, j)); i += 1; j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return out
    }

    /// Order-preserving pairing that maximizes total similarity, counting only pairs at or
    /// above the threshold.
    static func alignBySimilarity(
        _ oldGap: [Int], _ newGap: [Int], _ oldWords: [[String]], _ newWords: [[String]]
    ) -> [(Int, Int)] {
        let n = oldGap.count, m = newGap.count
        var sim = [[Double]](repeating: [Double](repeating: 0, count: m), count: n)
        for a in 0..<n {
            for b in 0..<m {
                let s = similarity(oldWords[oldGap[a]], newWords[newGap[b]])
                sim[a][b] = s >= editSimilarityThreshold ? s : 0
            }
        }
        // best[a][b] is the best total for oldGap[a...] and newGap[b...].
        var best = [[Double]](repeating: [Double](repeating: 0, count: m + 1), count: n + 1)
        for a in stride(from: n - 1, through: 0, by: -1) {
            for b in stride(from: m - 1, through: 0, by: -1) {
                var v = max(best[a + 1][b], best[a][b + 1])
                if sim[a][b] > 0 { v = max(v, best[a + 1][b + 1] + sim[a][b]) }
                best[a][b] = v
            }
        }
        var out: [(Int, Int)] = []
        var a = 0, b = 0
        while a < n && b < m {
            if sim[a][b] > 0 && best[a][b] == best[a + 1][b + 1] + sim[a][b] {
                out.append((oldGap[a], newGap[b])); a += 1; b += 1
            } else if best[a + 1][b] >= best[a][b + 1] {
                a += 1
            } else {
                b += 1
            }
        }
        return out
    }

    /// Normalized words, the same ones the scorer compares, so case and punctuation do not
    /// count as differences.
    static func words(_ text: String) -> [String] {
        Normalizer.tokenize(text).map(\.normalized)
    }

    /// One minus word-level edit distance over the longer length.
    static func similarity(_ a: [String], _ b: [String]) -> Double {
        if a.isEmpty || b.isEmpty { return 0 }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return 1 - Double(prev[b.count]) / Double(max(a.count, b.count))
    }
}
