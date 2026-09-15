import Foundation

/// Builds the scores CSV. Pure: passage and takes in, string out.
///
/// Lives in `Core/` so the test target compiles it. Revision 1 put the whole of export in
/// `Services/`, which the test target does not compile, so its escaping tests — the part it
/// itself called "the one worth writing carefully" — could never have linked.
public enum ScoreCSV {

    public static let header = [
        "date", "theme", "passage_title", "granularity", "target_index", "target_text",
        "take_timestamp", "accuracy", "word_error_rate", "verdict", "transcript",
        "problem_words",
    ]

    /// A byte-order mark, because Excel on macOS misreads UTF-8 without one and the whole
    /// point of this file is that it opens in a spreadsheet.
    public static let byteOrderMark = "\u{FEFF}"

    public static func build(
        passage: Passage,
        takes: [Take],
        timeZone: TimeZone = .current,
        includeByteOrderMark: Bool = true
    ) -> String {
        let dateFormatter = Paths.nameDateFormatter(timeZone: timeZone)
        // UTC with a Z suffix. A local offset is valid ISO 8601 but only sorts lexically
        // within one offset, and this file exists to be sorted in a spreadsheet.
        let iso = ISO8601DateFormatter()
        iso.timeZone = TimeZone(identifier: "UTC")
        iso.formatOptions = [.withInternetDateTime]

        // Target index is derived here from the current ordering, never read from a stored
        // ref. A stored index would silently re-point every historical take on a re-split.
        var indexFor: [TargetRef: Int] = [:]
        for (i, s) in passage.sentences.enumerated() { indexFor[.sentence(s.id)] = i }
        for (i, p) in passage.paragraphs.enumerated() { indexFor[.paragraph(p.id)] = i }
        indexFor[.passage(passage.id)] = 0

        var rows: [String] = [header.map(escape).joined(separator: ",")]

        for take in takes.sorted(by: { $0.recordedAt < $1.recordedAt }) {
            let score = take.score
            let fields = [
                dateFormatter.string(from: passage.createdAt),
                passage.theme ?? "",
                passage.title,
                take.target.kind.rawValue,
                indexFor[take.target].map(String.init) ?? "",
                take.referenceText,
                iso.string(from: take.recordedAt),
                score.map { String(format: "%.4f", $0.accuracy) } ?? "",
                score.map { String(format: "%.4f", $0.wordErrorRate) } ?? "",
                score?.verdict.rawValue ?? "",
                score?.transcript ?? "",
                score?.problemWords.joined(separator: "; ") ?? "",
            ]
            rows.append(fields.map(escape).joined(separator: ","))
        }

        let body = rows.joined(separator: "\r\n") + "\r\n"
        return includeByteOrderMark ? byteOrderMark + body : body
    }

    /// RFC 4180 quoting, plus a guard against formula injection.
    ///
    /// Quoting alone does not stop a spreadsheet evaluating a cell: it unquotes first and
    /// then parses. A cell beginning `=`, `+`, `-` or `@` is a formula in Excel, Numbers and
    /// LibreOffice, and the zip is explicitly meant to be shareable — so practice prose
    /// starting with a hyphen could run in a tutor's spreadsheet.
    public static func escape(_ field: String) -> String {
        var value = field

        // Scalar comparison, not Character comparison. "\r\n" is one grapheme cluster in
        // Swift, so `contains("\r")` is FALSE for CRLF text — which left the field unquoted
        // and broke the row. The same trap bit the parser below.
        let dangerousFirst: Set<Unicode.Scalar> = ["=", "+", "-", "@", "\t", "\r"]
        if let first = value.unicodeScalars.first, dangerousFirst.contains(first) {
            value = "'" + value
        }

        let mustQuote: Set<Unicode.Scalar> = [",", "\"", "\n", "\r"]
        let needsQuoting = value.unicodeScalars.contains { mustQuote.contains($0) }
        guard needsQuoting else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Strips the formula guard, so a round-trip test can compare against the original.
    public static func unescapeFormulaGuard(_ field: String) -> String {
        let dangerous: Set<Unicode.Scalar> = ["=", "+", "-", "@", "\t", "\r"]
        var scalars = Array(field.unicodeScalars)
        guard scalars.count >= 2, scalars[0] == "'", dangerous.contains(scalars[1]) else { return field }
        scalars.removeFirst()
        var out = String.UnicodeScalarView()
        for s in scalars { out.append(s) }
        return String(out)
    }

    // MARK: - Parsing, for round-trip tests

    /// A minimal RFC 4180 reader. String-equality assertions on CSV are exactly how the
    /// embedded-newline case gets missed, so the tests parse the output back instead.
    public static func parse(_ text: String) -> [[String]] {
        var input = Substring(text)
        if input.hasPrefix(byteOrderMark) { input = input.dropFirst() }

        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var i = input.startIndex

        while i < input.endIndex {
            let c = input[i]
            if inQuotes {
                if c == "\"" {
                    let next = input.index(after: i)
                    if next < input.endIndex, input[next] == "\"" {
                        field.append("\"")
                        i = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",":
                    row.append(field); field = ""
                // "\r\n" is a SINGLE Character in Swift -- a grapheme cluster -- so a
                // `case "\r"` alone never matches a CRLF pair, and the whole file parses as
                // one enormous field. This cost a debugging round; it is the kind of thing
                // that looks like a CSV bug and is actually a Unicode one.
                case "\r\n", "\r":
                    row.append(field); field = ""
                    rows.append(row); row = []
                case "\n":
                    row.append(field); field = ""
                    rows.append(row); row = []
                default:
                    field.append(c)
                }
            }
            i = input.index(after: i)
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}
