import SwiftUI

/// Shared visual vocabulary. Deliberately small.
enum Styling {

    // MARK: - Palette
    //
    // Light and warm, on purpose. The app followed the system appearance, which on this Mac
    // is dark, so practice happened against near-black -- reported as "the theme color is
    // black, which is not beautiful". Reading aloud is a daylight activity and the page you
    // read from should look like paper, not like a terminal.
    //
    // Two colors do all the work, which is what keeps this from becoming a theme system:
    //
    //   accent    teal, for anything you can press. Calm rather than loud, because every
    //             row has a transport and a row of saturated buttons would shout.
    //   highlight amber, and ONLY for the word being spoken. It reads as a highlighter pen
    //             drawn over paper, which is exactly what it is doing.
    //
    // Keeping those two apart matters: a single accent used for both would make the spoken
    // word look like another button.

    /// The page. A warm off-white rather than pure white, which is glaring at length.
    static let canvas = Color(red: 0.980, green: 0.969, blue: 0.949)

    /// Cards and sheets that sit on the canvas.
    static let surface = Color.white

    /// Anything interactive.
    static let accent = Color(red: 0.102, green: 0.510, blue: 0.455)

    /// The word being spoken, and nothing else.
    static let highlight = Color(red: 0.976, green: 0.773, blue: 0.325)

    /// The row being worked on. Barely there: it marks the row without boxing it in, which
    /// is what the single-column layout depends on.
    static let activeRow = accent.opacity(0.07)

    /// Hairline under the header. Warmer and lighter than a system separator, which looks
    /// like a crack on a cream background.
    static let rule = Color(red: 0.882, green: 0.859, blue: 0.824)

    // The score bands. Colors carry the band; the muted line beneath names the problem
    // words in text, because color alone is not accessible.
    /// Darkened against the light canvas. System `.green` and `.mint` are tuned to carry on
    /// a dark background and wash out to near-invisible pastels on cream.
    static func accuracyColor(_ accuracy: Double) -> Color {
        switch accuracy {
        case 0.95...: return Color(red: 0.133, green: 0.502, blue: 0.290)
        case 0.85..<0.95: return Color(red: 0.180, green: 0.541, blue: 0.482)
        case 0.70..<0.85: return Color(red: 0.761, green: 0.471, blue: 0.106)
        default: return Color(red: 0.722, green: 0.231, blue: 0.188)
        }
    }

    static func accuracyBand(_ accuracy: Double) -> String {
        switch accuracy {
        case 0.95...: return "very close"
        case 0.85..<0.95: return "a few words to work on"
        case 0.70..<0.85: return "several words to work on"
        default: return "most words were missed"
        }
    }

    static func percent(_ accuracy: Double) -> String {
        "\(Int((accuracy * 100).rounded()))"
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f
    }()

    static let longDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    static let takeTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    /// Plain text with its markdown formatting drawn back on.
    ///
    /// Through intents rather than fonts, so bold and italic compose with each other and
    /// with whatever size the row uses -- a bold word in a heading stays heading-sized.
    /// The characters are exactly `text`, which is what keeps the speech highlight, built
    /// from offsets into the same string, landing on the word being spoken.
    static func formatted(_ text: String, styles: [InlineStyle], color: Color) -> AttributedString {
        var out = AttributedString(text)
        out.foregroundColor = color
        for style in styles {
            guard let r = SpokenRange.range(in: text, utf16Location: style.location, utf16Length: style.length),
                  let range = Range(r, in: out) else { continue }
            switch style.kind {
            case .strong: addIntent(.stronglyEmphasized, to: range, in: &out)
            case .emphasis: addIntent(.emphasized, to: range, in: &out)
            case .code: addIntent(.code, to: range, in: &out)
            case .strikethrough: addIntent(.strikethrough, to: range, in: &out)
            case .link:
                // A link is pressable, so it takes the accent, like everything else that is.
                out[range].link = style.url.flatMap(URL.init(string:))
                out[range].foregroundColor = accent
            }
        }
        return out
    }

    /// Unions rather than assigns, so a word both bold and italic keeps both.
    private static func addIntent(
        _ intent: InlinePresentationIntent, to range: Range<AttributedString.Index>, in out: inout AttributedString
    ) {
        let pieces = out[range].runs.map { ($0.range, $0.inlinePresentationIntent ?? []) }
        for (r, existing) in pieces {
            out[r].inlinePresentationIntent = existing.union(intent)
        }
    }

    /// Row text size for a markdown heading, stepping down to body size by level four.
    static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 21
        case 2: return 18
        default: return 16
        }
    }

    /// The word diff as one attributed string, which wraps natively and needs no custom
    /// layout. Matched words read as ordinary muted text; close misses are amber; wrong or
    /// dropped words are red. No underlines, no strikethrough, no italics — color alone
    /// keeps it readable as a sentence rather than as markup.
    static func diff(_ words: [WordResult]) -> AttributedString {
        var out = AttributedString()
        for (i, w) in words.enumerated() {
            var piece = AttributedString(w.status == .extra ? w.display.lowercased() : w.display)
            switch w.status {
            case .match:
                piece.foregroundColor = .secondary
            case .partial:
                piece.foregroundColor = .orange
            case .substituted, .missed:
                piece.foregroundColor = .red
            case .extra:
                piece.foregroundColor = Color.secondary.opacity(0.6)
            }
            out += piece
            if i < words.count - 1 { out += AttributedString(" ") }
        }
        return out
    }
}
