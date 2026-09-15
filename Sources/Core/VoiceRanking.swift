import Foundation

/// Quality tiers, mirroring `AVSpeechSynthesisVoiceQuality` without importing AVFoundation.
public enum VoiceTier: Int, Codable, Sendable, Comparable, CaseIterable {
    case compact = 1
    case enhanced = 2
    case premium = 3

    public static func < (a: VoiceTier, b: VoiceTier) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .compact: return "basic"
        case .enhanced: return "enhanced"
        case .premium: return "premium"
        }
    }

    /// Everything preinstalled is `compact`, which is the whole reason built-in speech
    /// sounds robotic.
    public var isGoodEnough: Bool { self >= .enhanced }
}

public struct VoiceOption: Sendable, Equatable, Identifiable {
    /// The stable identifier. Selection and persistence key on this, never on the name:
    /// voice names are localized, so matching "Ava" as a string fails on a non-English
    /// system UI.
    public var id: String
    public var name: String
    public var language: String
    public var tier: VoiceTier

    public init(id: String, name: String, language: String, tier: VoiceTier) {
        self.id = id
        self.name = name
        self.language = language
        self.tier = tier
    }

    public var isAmericanEnglish: Bool { language.hasPrefix("en-US") || language.hasPrefix("en_US") }
    public var isEnglish: Bool { language.hasPrefix("en") }

    /// Voice family, inferred from the identifier.
    ///
    /// This exists because of what the probe actually returned. With every installed voice
    /// at the same tier, ranking by tier then name picked **Albert** — one of the old
    /// MacinTalk novelty voices, alongside Bad News, Bubbles, Trinoids and Zarvox. It is
    /// technically a voice and it is useless as a pronunciation reference. Family rank puts
    /// the real speech voices ahead of the toys.
    public var family: VoiceFamily {
        // Observed identifiers, not guessed ones. The asset catalog advertises Ava as
        // `com.apple.ttsbundle.Ava`, but once installed it reports
        // `com.apple.voice.premium.en-US.Ava` — so both prefixes are real and a rule based
        // on the catalog alone would have been wrong.
        if id.hasPrefix("com.apple.voice.premium") { return .downloadable }
        if id.hasPrefix("com.apple.voice.enhanced") { return .downloadable }
        if id.hasPrefix("com.apple.ttsbundle") { return .downloadable }
        if id.hasPrefix("com.apple.voice") { return .system }
        if id.hasPrefix("com.apple.eloquence") { return .eloquence }
        if id.hasPrefix("com.apple.speech.synthesis.voice") { return .novelty }
        return .system
    }
}

/// Ordered worst to best, so a higher raw value wins.
public enum VoiceFamily: Int, Sendable, Comparable, CaseIterable {
    /// The old MacinTalk set: Albert, Bad News, Bubbles, Trinoids, Zarvox and friends.
    /// Speech, technically. Not a pronunciation reference.
    case novelty = 0
    /// The Eloquence set. Intelligible, very synthetic.
    case eloquence = 1
    /// Preinstalled real voices, such as Samantha.
    case system = 2
    /// Downloaded voices, which is where enhanced and premium live.
    case downloadable = 3

    public static func < (a: VoiceFamily, b: VoiceFamily) -> Bool { a.rawValue < b.rawValue }
}

/// Picks the reference voice, as a pure function.
///
/// Revision 1 verified voice selection by ear only, so a change silently reverting to the
/// system compact voice — the exact bug the item exists to fix — would have been inaudible
/// to anyone who had forgotten the baseline.
public enum VoiceRanking {

    /// Tier first, then family, then American English, then name for stability.
    ///
    /// Family has to be in here. Every preinstalled voice is the same tier, so without it
    /// the tie-break fell through to alphabetical and selected a novelty voice.
    public static func ranked(_ voices: [VoiceOption]) -> [VoiceOption] {
        voices
            .filter(\.isEnglish)
            .sorted { a, b in
                if a.tier != b.tier { return a.tier > b.tier }
                if a.family != b.family { return a.family > b.family }
                if a.isAmericanEnglish != b.isAmericanEnglish { return a.isAmericanEnglish }
                return a.name < b.name
            }
    }

    /// The best installed English voice, **never the system default**, because the system
    /// default is the compact voice that started this problem.
    public static func best(_ voices: [VoiceOption]) -> VoiceOption? {
        ranked(voices).first
    }

    /// Resolves the user's stored choice, falling back to the best installed.
    public static func resolve(preferred id: String?, from voices: [VoiceOption]) -> VoiceOption? {
        if let id, let match = voices.first(where: { $0.id == id }) { return match }
        return best(voices)
    }

    /// True when nothing above the lowest tier is installed, so the banner is warranted.
    public static func needsBetterVoice(_ voices: [VoiceOption]) -> Bool {
        !voices.contains { $0.isEnglish && $0.tier.isGoodEnough }
    }

    /// Grouped for the picker, best tier first. Deliberately does not enumerate locales:
    /// constructing a recognizer for an unsupported locale writes asset warnings to the
    /// system log.
    public static func grouped(_ voices: [VoiceOption]) -> [(tier: VoiceTier, voices: [VoiceOption])] {
        let r = ranked(voices)
        return VoiceTier.allCases.reversed().compactMap { tier in
            let group = r.filter { $0.tier == tier }
            return group.isEmpty ? nil : (tier, group)
        }
    }
}

/// Converts a synthesizer's UTF-16 range into a Swift string range.
///
/// `willSpeakRangeOfSpeechString` reports offsets in UTF-16 code units. Slicing with
/// `Array(text)[range]` is wrong and drifts on any accented character or emoji — which is
/// exactly the kind of bug that shows up as "highlighting is slightly off" weeks later.
public enum SpokenRange {

    /// nil when the range does not map onto the string, which is a supported case rather
    /// than a crash.
    ///
    /// Bounds are checked against the UTF-16 view before constructing an index.
    /// `String.Index(utf16Offset:in:)` is non-failing, so it cannot be used to *test*
    /// whether an offset is valid — it will happily hand back something unusable.
    public static func range(in text: String, utf16Location: Int, utf16Length: Int) -> Range<String.Index>? {
        guard utf16Location >= 0, utf16Length >= 0 else { return nil }
        let unitCount = text.utf16.count
        let upper = utf16Location + utf16Length
        guard utf16Location <= unitCount, upper <= unitCount else { return nil }

        let start = String.Index(utf16Offset: utf16Location, in: text)
        let end = String.Index(utf16Offset: upper, in: text)

        // An offset landing inside a surrogate pair or a grapheme cluster is not a valid
        // character boundary, and slicing on it would be wrong rather than merely odd.
        guard start.samePosition(in: text) != nil, end.samePosition(in: text) != nil else { return nil }
        guard start <= end else { return nil }
        return start..<end
    }

    public static func substring(in text: String, utf16Location: Int, utf16Length: Int) -> String? {
        guard let r = range(in: text, utf16Location: utf16Location, utf16Length: utf16Length) else { return nil }
        return String(text[r])
    }
}
