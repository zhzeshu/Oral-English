import SwiftUI

/// Shared visual vocabulary. Deliberately small.
enum Styling {

    // The score bands. Colors carry the band; the muted line beneath names the problem
    // words in text, because color alone is not accessible.
    static func accuracyColor(_ accuracy: Double) -> Color {
        switch accuracy {
        case 0.95...: return .green
        case 0.85..<0.95: return .mint
        case 0.70..<0.85: return .orange
        default: return .red
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
