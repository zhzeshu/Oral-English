import Foundation
import Testing

@Suite("ScoreCSV")
struct ScoreCSVTests {

    static let t0 = ISO8601DateFormatter().date(from: "2026-09-14T20:17:33Z")!.wholeSecond

    static func passage(theme: String? = "Interview prep", title: String = "The fog came in") -> Passage {
        let text = "The fog came in. It sat looking over harbor.\n\nThen it moved on."
        let split = SentenceSplitter.split(text)
        return Passage(title: title, theme: theme, createdAt: t0, updatedAt: t0,
                       sourceText: text, paragraphs: split.paragraphs, sentences: split.sentences)
    }

    static func take(
        for ref: TargetRef, referenceText: String, transcript: String = "the fog came in",
        accuracy: Double = 0.875, problem: [String] = ["harbor"], at date: Date = t0
    ) -> Take {
        let words = problem.map {
            WordResult(targetIndex: 0, display: $0, normalized: $0, heard: nil, status: .missed)
        }
        let score = ScoreReport(
            accuracy: accuracy, wordErrorRate: 1 - accuracy, rawWeightedError: 1,
            matchCount: 7, partialCount: 0, substitutionCount: 0, missedCount: problem.count,
            extraCount: 0, referenceTokenCount: 8, transcript: transcript,
            meanConfidence: 0.8, verdict: .clear, engine: "test",
            localeIdentifier: "en-US", scoredAt: date, words: words)
        return Take(target: ref, recordedAt: date, audioPath: "takes/x.m4a",
                    durationSeconds: 3.4, referenceText: referenceText, score: score)
    }

    // MARK: - Shape

    @Test("the header names every column")
    func headerColumns() {
        let p = Self.passage()
        let csv = ScoreCSV.build(passage: p, takes: [])
        let rows = ScoreCSV.parse(csv)
        #expect(rows.count == 1, "header only when there are no takes")
        for column in ["date", "theme", "granularity", "target_index", "target_text",
                       "take_timestamp", "accuracy", "word_error_rate", "transcript", "problem_words"] {
            #expect(rows[0].contains(column), "missing column \(column)")
        }
    }

    @Test("a passage with no takes yields a valid header-only file")
    func noTakes() {
        let csv = ScoreCSV.build(passage: Self.passage(), takes: [])
        #expect(!csv.isEmpty)
        #expect(ScoreCSV.parse(csv).count == 1)
    }

    @Test("one row per take, across all three granularities")
    func rowPerTake() {
        let p = Self.passage()
        let takes = [
            Self.take(for: .sentence(p.sentences[0].id), referenceText: p.sentences[0].text, at: Self.t0),
            Self.take(for: .paragraph(p.paragraphs[0].id), referenceText: p.paragraphs[0].text, at: Self.t0.addingTimeInterval(60)),
            Self.take(for: .passage(p.id), referenceText: p.text(for: .passage(p.id))!, at: Self.t0.addingTimeInterval(120)),
        ]
        let rows = ScoreCSV.parse(ScoreCSV.build(passage: p, takes: takes))
        #expect(rows.count == 4, "header plus three takes, got \(rows.count)")
        let granularityColumn = ScoreCSV.header.firstIndex(of: "granularity")!
        #expect(Set(rows.dropFirst().map { $0[granularityColumn] }) == ["sentence", "paragraph", "passage"])
    }

    @Test("a file with no byte-order mark still parses, and one with it is the default")
    func byteOrderMark() {
        let p = Self.passage()
        #expect(ScoreCSV.build(passage: p, takes: []).hasPrefix(ScoreCSV.byteOrderMark))
        let without = ScoreCSV.build(passage: p, takes: [], includeByteOrderMark: false)
        #expect(!without.hasPrefix(ScoreCSV.byteOrderMark))
        #expect(ScoreCSV.parse(without).count == 1)
    }

    // MARK: - Escaping

    @Test("a comma round-trips")
    func commaRoundTrips() {
        let text = "Then, at four, it moved on."
        let p = Self.passage()
        let rows = ScoreCSV.parse(ScoreCSV.build(
            passage: p, takes: [Self.take(for: .sentence(p.sentences[0].id), referenceText: text)]))
        let col = ScoreCSV.header.firstIndex(of: "target_text")!
        #expect(rows[1][col] == text)
    }

    @Test("a quote round-trips")
    func quoteRoundTrips() {
        let text = #"He said "the fog" quietly."#
        let p = Self.passage()
        let rows = ScoreCSV.parse(ScoreCSV.build(
            passage: p, takes: [Self.take(for: .sentence(p.sentences[0].id), referenceText: text)]))
        let col = ScoreCSV.header.firstIndex(of: "target_text")!
        #expect(rows[1][col] == text)
    }

    /// The case revision 1 missed, and it is guaranteed on every whole-passage row, because
    /// whole-passage target text is paragraphs joined by a blank line.
    @Test("embedded newlines round-trip", arguments: [
        "First line.\nSecond line.",
        "First para.\n\nSecond para.",
        "CRLF line.\r\nNext line.",
    ])
    func newlinesRoundTrip(text: String) {
        let p = Self.passage()
        let rows = ScoreCSV.parse(ScoreCSV.build(
            passage: p, takes: [Self.take(for: .sentence(p.sentences[0].id), referenceText: text)]))
        let col = ScoreCSV.header.firstIndex(of: "target_text")!
        #expect(rows.count == 2, "an embedded newline must not create a new row")
        // The reader normalizes CRLF to LF inside a quoted field, so compare on that basis.
        #expect(rows[1][col].replacingOccurrences(of: "\r\n", with: "\n")
                == text.replacingOccurrences(of: "\r\n", with: "\n"))
    }

    @Test("a real whole-passage row does not break the file")
    func wholePassageRow() {
        let p = Self.passage()
        let wholeText = p.text(for: .passage(p.id))!
        #expect(wholeText.contains("\n\n"), "the premise: whole-passage text contains blank lines")
        let rows = ScoreCSV.parse(ScoreCSV.build(
            passage: p, takes: [Self.take(for: .passage(p.id), referenceText: wholeText)]))
        #expect(rows.count == 2)
    }

    /// Quoting does not stop a spreadsheet evaluating a cell: it unquotes first, then
    /// parses. The zip is meant to be shared, so this could run in someone else's Excel.
    @Test("a cell that would be read as a formula is neutralized", arguments: [
        "=HYPERLINK(\"http://example.com\")",
        "+1234",
        "-leading hyphen, which is ordinary prose",
        "@SUM(A1)",
    ])
    func formulaInjectionNeutralized(text: String) {
        let p = Self.passage()
        let rows = ScoreCSV.parse(ScoreCSV.build(
            passage: p, takes: [Self.take(for: .sentence(p.sentences[0].id), referenceText: text)]))
        let col = ScoreCSV.header.firstIndex(of: "target_text")!
        let cell = rows[1][col]
        #expect(cell.hasPrefix("'"), "expected a guard prefix, got \(cell)")
        #expect(ScoreCSV.unescapeFormulaGuard(cell) == text, "the original must still be recoverable")
    }

    @Test("ordinary text is not given a formula guard")
    func ordinaryTextUnguarded() {
        #expect(ScoreCSV.escape("The fog came in.") == "The fog came in.")
        #expect(ScoreCSV.escape("3 apples") == "3 apples")
    }

    @Test("multiple problem words in one field are escaped within the field")
    func multipleProblemWords() {
        let p = Self.passage()
        let rows = ScoreCSV.parse(ScoreCSV.build(
            passage: p,
            takes: [Self.take(for: .sentence(p.sentences[0].id),
                              referenceText: p.sentences[0].text,
                              problem: ["harbor", "city", "feet"])]))
        let col = ScoreCSV.header.firstIndex(of: "problem_words")!
        #expect(rows[1][col] == "harbor; city; feet")
    }

    @Test("accented text survives, because only scoring folds to ASCII")
    func accentsSurvive() {
        let p = Self.passage()
        let rows = ScoreCSV.parse(ScoreCSV.build(
            passage: p, takes: [Self.take(for: .sentence(p.sentences[0].id), referenceText: "Café résumé.")]))
        let col = ScoreCSV.header.firstIndex(of: "target_text")!
        #expect(rows[1][col] == "Café résumé.")
    }

    // MARK: - Sorting and dates

    @Test("timestamps are ISO 8601, so a spreadsheet sorts them")
    func isoTimestamps() {
        let p = Self.passage()
        let rows = ScoreCSV.parse(ScoreCSV.build(
            passage: p, takes: [Self.take(for: .sentence(p.sentences[0].id), referenceText: "x")]))
        let col = ScoreCSV.header.firstIndex(of: "take_timestamp")!
        #expect(rows[1][col].contains("2026-09-14"))
        #expect(rows[1][col].contains("T"))
    }

    @Test("rows come out oldest first")
    func rowsSorted() {
        let p = Self.passage()
        let ref = TargetRef.sentence(p.sentences[0].id)
        let takes = [
            Self.take(for: ref, referenceText: "third", at: Self.t0.addingTimeInterval(120)),
            Self.take(for: ref, referenceText: "first", at: Self.t0),
            Self.take(for: ref, referenceText: "second", at: Self.t0.addingTimeInterval(60)),
        ]
        let rows = ScoreCSV.parse(ScoreCSV.build(passage: p, takes: takes))
        let col = ScoreCSV.header.firstIndex(of: "target_text")!
        #expect(rows.dropFirst().map { $0[col] } == ["first", "second", "third"])
    }

    @Test("an unscored take still produces a row, with empty score columns")
    func unscoredTake() {
        let p = Self.passage()
        let take = Take(target: .sentence(p.sentences[0].id), recordedAt: Self.t0,
                        audioPath: "takes/x.m4a", durationSeconds: 1, referenceText: "x")
        let rows = ScoreCSV.parse(ScoreCSV.build(passage: p, takes: [take]))
        #expect(rows.count == 2)
        let col = ScoreCSV.header.firstIndex(of: "accuracy")!
        #expect(rows[1][col].isEmpty)
    }

    @Test("a passage with no theme leaves that column empty rather than writing nil")
    func noTheme() {
        let p = Self.passage(theme: nil)
        let rows = ScoreCSV.parse(ScoreCSV.build(
            passage: p, takes: [Self.take(for: .sentence(p.sentences[0].id), referenceText: "x")]))
        let col = ScoreCSV.header.firstIndex(of: "theme")!
        #expect(rows[1][col].isEmpty)
    }

    @Test("every row has the same number of columns as the header")
    func columnCountsMatch() {
        let p = Self.passage()
        let ref = TargetRef.sentence(p.sentences[0].id)
        let takes = [
            Self.take(for: ref, referenceText: "a,b", at: Self.t0),
            Self.take(for: ref, referenceText: "line\nbreak", at: Self.t0.addingTimeInterval(1)),
            Self.take(for: ref, referenceText: "=formula", at: Self.t0.addingTimeInterval(2)),
        ]
        let rows = ScoreCSV.parse(ScoreCSV.build(passage: p, takes: takes))
        for (i, row) in rows.enumerated() {
            #expect(row.count == ScoreCSV.header.count, "row \(i) has \(row.count) columns")
        }
    }
}
