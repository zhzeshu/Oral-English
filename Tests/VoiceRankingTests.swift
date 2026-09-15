import Foundation
import Testing

@Suite("VoiceRanking")
struct VoiceRankingTests {

    static let compactSamantha = VoiceOption(
        id: "com.apple.voice.compact.en-US.Samantha", name: "Samantha", language: "en-US", tier: .compact)
    static let premiumAva = VoiceOption(
        id: "com.apple.ttsbundle.Ava", name: "Ava", language: "en-US", tier: .premium)
    static let enhancedAllison = VoiceOption(
        id: "com.apple.ttsbundle.Allison", name: "Allison", language: "en-US", tier: .enhanced)
    static let premiumSerenaGB = VoiceOption(
        id: "com.apple.ttsbundle.Serena", name: "Serena", language: "en-GB", tier: .premium)
    static let frenchAmelie = VoiceOption(
        id: "com.apple.voice.compact.fr-FR.Amelie", name: "Amélie", language: "fr-FR", tier: .compact)

    @Test("a premium voice wins when one is installed")
    func premiumWins() {
        let best = VoiceRanking.best([Self.compactSamantha, Self.enhancedAllison, Self.premiumAva])
        #expect(best?.id == Self.premiumAva.id)
    }

    @Test("enhanced wins when there is no premium")
    func enhancedWins() {
        let best = VoiceRanking.best([Self.compactSamantha, Self.enhancedAllison])
        #expect(best?.id == Self.enhancedAllison.id)
    }

    @Test("American English is preferred within a tier")
    func americanPreferred() {
        let best = VoiceRanking.best([Self.premiumSerenaGB, Self.premiumAva])
        #expect(best?.id == Self.premiumAva.id)
    }

    @Test("non-English voices are excluded entirely")
    func nonEnglishExcluded() {
        #expect(VoiceRanking.best([Self.frenchAmelie]) == nil)
        #expect(VoiceRanking.ranked([Self.frenchAmelie, Self.compactSamantha]).count == 1)
    }

    /// The bug this item exists to fix. The system default is the compact voice.
    @Test("selection never returns compact when something better exists")
    func neverCompactWhenBetterExists() {
        for better in [Self.enhancedAllison, Self.premiumAva] {
            let best = VoiceRanking.best([Self.compactSamantha, better])
            #expect(best?.tier.isGoodEnough == true, "picked \(best?.name ?? "nil")")
            #expect(best?.id != Self.compactSamantha.id)
        }
    }

    @Test("an all-compact list still returns a voice, and flags that the banner is needed")
    func allCompact() {
        let voices = [Self.compactSamantha]
        #expect(VoiceRanking.best(voices)?.id == Self.compactSamantha.id, "speech must still work")
        #expect(VoiceRanking.needsBetterVoice(voices), "and the banner must be warranted")
    }

    @Test("with a good voice installed the banner is not warranted")
    func goodVoiceNoBanner() {
        #expect(!VoiceRanking.needsBetterVoice([Self.compactSamantha, Self.premiumAva]))
        #expect(!VoiceRanking.needsBetterVoice([Self.enhancedAllison]))
    }

    @Test("an empty list warrants the banner and yields no voice")
    func emptyList() {
        #expect(VoiceRanking.best([]) == nil)
        #expect(VoiceRanking.needsBetterVoice([]))
    }

    @Test("a stored preference is honored when the voice is still installed")
    func honorsStoredPreference() {
        let all = [Self.compactSamantha, Self.enhancedAllison, Self.premiumAva]
        #expect(VoiceRanking.resolve(preferred: Self.enhancedAllison.id, from: all)?.id == Self.enhancedAllison.id)
    }

    @Test("a stored preference for an uninstalled voice falls back to the best installed")
    func fallsBackWhenPreferenceMissing() {
        let all = [Self.compactSamantha, Self.premiumAva]
        #expect(VoiceRanking.resolve(preferred: "com.apple.ttsbundle.NotInstalled", from: all)?.id == Self.premiumAva.id)
    }

    @Test("selection keys on identifier, not on the localized display name")
    func keysOnIdentifier() {
        // Same voice, name localized differently. Matching on name would fail.
        let localized = VoiceOption(id: Self.premiumAva.id, name: "Ава", language: "en-US", tier: .premium)
        #expect(VoiceRanking.resolve(preferred: Self.premiumAva.id, from: [localized])?.id == Self.premiumAva.id)
    }

    @Test("ranking is stable across repeated calls")
    func stableRanking() {
        let all = [Self.premiumSerenaGB, Self.compactSamantha, Self.premiumAva, Self.enhancedAllison]
        #expect(VoiceRanking.ranked(all).map(\.id) == VoiceRanking.ranked(all).map(\.id))
    }

    @Test("grouping puts the best tier first and omits empty tiers")
    func grouping() {
        let groups = VoiceRanking.grouped([Self.compactSamantha, Self.premiumAva])
        #expect(groups.map(\.tier) == [.premium, .compact])
        #expect(groups.first?.voices.first?.id == Self.premiumAva.id)
    }

    @Test("tier labels are the words the picker shows")
    func tierLabels() {
        #expect(VoiceTier.premium.label == "premium")
        #expect(VoiceTier.enhanced.label == "enhanced")
        #expect(VoiceTier.compact.label == "basic")
        #expect(VoiceTier.premium > VoiceTier.enhanced)
        #expect(VoiceTier.enhanced > VoiceTier.compact)
    }
}

@Suite("SpokenRange")
struct SpokenRangeTests {

    /// The conversion that drifts if you slice a Character array instead.
    @Test("plain ASCII maps exactly")
    func ascii() {
        let text = "The quick brown fox"
        #expect(SpokenRange.substring(in: text, utf16Location: 4, utf16Length: 5) == "quick")
        #expect(SpokenRange.substring(in: text, utf16Location: 0, utf16Length: 3) == "The")
    }

    @Test("an accented character does not shift later offsets")
    func accented() {
        // "café" is 4 UTF-16 units when composed; the word after it starts at 5.
        let text = "café time"
        #expect(SpokenRange.substring(in: text, utf16Location: 0, utf16Length: 4) == "café")
        #expect(SpokenRange.substring(in: text, utf16Location: 5, utf16Length: 4) == "time")
    }

    /// An emoji is two UTF-16 code units. Character-array slicing gets this wrong.
    @Test("an emoji occupies two UTF-16 units and later words still resolve")
    func emoji() {
        let text = "hi 🎉 there"
        #expect(text.utf16.count == 11, "h,i,space + 2 for the emoji + space + there")
        #expect(SpokenRange.substring(in: text, utf16Location: 0, utf16Length: 2) == "hi")
        #expect(SpokenRange.substring(in: text, utf16Location: 6, utf16Length: 5) == "there")
    }

    @Test("a range that does not map returns nil rather than trapping", arguments: [
        (1000, 5), (-1, 3), (0, 1000), (5, -1),
    ] as [(Int, Int)])
    func outOfBounds(location: Int, length: Int) {
        #expect(SpokenRange.range(in: "short", utf16Location: location, utf16Length: length) == nil)
    }

    @Test("a zero-length range is empty, not nil")
    func zeroLength() {
        #expect(SpokenRange.substring(in: "text", utf16Location: 2, utf16Length: 0) == "")
    }

    @Test("an empty string only accepts the empty range")
    func emptyString() {
        #expect(SpokenRange.substring(in: "", utf16Location: 0, utf16Length: 0) == "")
        #expect(SpokenRange.range(in: "", utf16Location: 0, utf16Length: 1) == nil)
    }

    @Test("every word of a real sentence resolves by UTF-16 offset")
    func everyWordResolves() {
        let text = "The fog came in on little cat feet."
        var offset = 0
        var found: [String] = []
        for word in text.split(separator: " ") {
            let length = word.utf16.count
            if let s = SpokenRange.substring(in: text, utf16Location: offset, utf16Length: length) {
                found.append(s)
            }
            offset += length + 1
        }
        #expect(found == ["The", "fog", "came", "in", "on", "little", "cat", "feet."])
    }
}

/// Added after the probe revealed that ranking by tier and name alone picks a novelty
/// voice, because every preinstalled voice is the same tier.
@Suite("VoiceRanking families")
struct VoiceFamilyTests {

    static let albert = VoiceOption(
        id: "com.apple.speech.synthesis.voice.Albert", name: "Albert", language: "en-US", tier: .compact)
    static let zarvox = VoiceOption(
        id: "com.apple.speech.synthesis.voice.Zarvox", name: "Zarvox", language: "en-US", tier: .compact)
    static let samantha = VoiceOption(
        id: "com.apple.voice.compact.en-US.Samantha", name: "Samantha", language: "en-US", tier: .compact)
    static let eddy = VoiceOption(
        id: "com.apple.eloquence.en-US.Eddy", name: "Eddy", language: "en-US", tier: .compact)
    static let ava = VoiceOption(
        id: "com.apple.ttsbundle.Ava", name: "Ava", language: "en-US", tier: .premium)

    @Test("families are inferred from the identifier")
    func familyInference() {
        #expect(Self.albert.family == .novelty)
        #expect(Self.samantha.family == .system)
        #expect(Self.eddy.family == .eloquence)
        #expect(Self.ava.family == .downloadable)
    }

    /// The bug the probe caught: Albert sorts before Samantha alphabetically.
    @Test("a real voice beats a novelty voice at the same tier")
    func realBeatsNovelty() {
        let best = VoiceRanking.best([Self.albert, Self.samantha, Self.zarvox])
        #expect(best?.id == Self.samantha.id, "picked \(best?.name ?? "nil")")
    }

    @Test("a novelty voice is never selected when anything else exists", arguments: [
        "com.apple.voice.compact.en-US.Samantha",
        "com.apple.eloquence.en-US.Eddy",
        "com.apple.ttsbundle.Ava",
    ])
    func noveltyNeverWins(otherID: String) {
        let other = VoiceOption(id: otherID, name: "Zzz other", language: "en-US",
                                tier: otherID.contains("ttsbundle") ? .premium : .compact)
        let best = VoiceRanking.best([Self.albert, other])
        #expect(best?.id == otherID, "picked \(best?.name ?? "nil") over \(otherID)")
    }

    @Test("a novelty voice is still returned when it is genuinely all there is")
    func noveltyLastResort() {
        #expect(VoiceRanking.best([Self.albert, Self.zarvox])?.id == Self.albert.id)
    }

    @Test("tier still outranks family")
    func tierOutranksFamily() {
        // A downloadable compact voice must not beat a premium one.
        let compactDownloadable = VoiceOption(
            id: "com.apple.ttsbundle.Basic", name: "AAA", language: "en-US", tier: .compact)
        #expect(VoiceRanking.best([compactDownloadable, Self.ava])?.id == Self.ava.id)
    }

    @Test("the full realistic preinstalled set selects Samantha")
    func realisticSet() {
        let novelty = ["Albert", "Bad News", "Bells", "Bubbles", "Trinoids", "Zarvox", "Jester"]
            .map { VoiceOption(id: "com.apple.speech.synthesis.voice.\($0)", name: $0,
                               language: "en-US", tier: .compact) }
        let eloquence = ["Eddy", "Flo", "Reed", "Rocko", "Sandy", "Shelley"]
            .map { VoiceOption(id: "com.apple.eloquence.en-US.\($0)", name: $0,
                               language: "en-US", tier: .compact) }
        let all = novelty + eloquence + [Self.samantha]
        #expect(VoiceRanking.best(all)?.id == Self.samantha.id)
    }
}

/// Pins the identifiers this machine actually reports, so a future refactor cannot quietly
/// change how a real installed voice is classified.
@Suite("VoiceRanking observed identifiers")
struct ObservedVoiceTests {

    /// The installed identifier differs from the one the asset catalog advertises. The
    /// catalog says `com.apple.ttsbundle.Ava`; the installed voice reports
    /// `com.apple.voice.premium.en-US.Ava`. Matching on the catalog id alone would fail.
    static let avaAsInstalled = VoiceOption(
        id: "com.apple.voice.premium.en-US.Ava",
        name: "Ava (Premium)", language: "en-US", tier: .premium)

    static let samanthaAsInstalled = VoiceOption(
        id: "com.apple.voice.compact.en-US.Samantha",
        name: "Samantha", language: "en-US", tier: .compact)

    @Test("the installed premium identifier is classified as downloadable")
    func premiumPrefixRecognized() {
        #expect(Self.avaAsInstalled.family == .downloadable)
        #expect(Self.samanthaAsInstalled.family == .system)
    }

    @Test("both advertised and installed premium prefixes are recognized", arguments: [
        "com.apple.voice.premium.en-US.Ava",
        "com.apple.voice.enhanced.en-US.Allison",
        "com.apple.ttsbundle.Ava",
    ])
    func bothPrefixesRecognized(id: String) {
        let v = VoiceOption(id: id, name: "x", language: "en-US", tier: .premium)
        #expect(v.family == .downloadable, "\(id) was classified \(v.family)")
    }

    /// The realistic post-install set, exactly as this machine reports it.
    @Test("with Ava installed, ranking selects Ava over all 41 preinstalled voices")
    func avaWinsAgainstTheRealSet() {
        let novelty = ["Albert", "Bad News", "Bells", "Bubbles", "Trinoids", "Zarvox", "Jester",
                       "Whisper", "Organ", "Cellos", "Boing", "Bahh", "Good News", "Junior",
                       "Kathy", "Ralph", "Fred", "Superstar", "Wobble"]
            .map { VoiceOption(id: "com.apple.speech.synthesis.voice.\($0.replacingOccurrences(of: " ", with: ""))",
                               name: $0, language: "en-US", tier: .compact) }
        let eloquence = ["Eddy", "Flo", "Grandma", "Grandpa", "Reed", "Rocko", "Sandy", "Shelley"]
            .map { VoiceOption(id: "com.apple.eloquence.en-US.\($0)", name: $0,
                               language: "en-US", tier: .compact) }
        let all = novelty + eloquence + [Self.samanthaAsInstalled, Self.avaAsInstalled]

        let best = VoiceRanking.best(all)
        #expect(best?.id == Self.avaAsInstalled.id, "picked \(best?.name ?? "nil")")
        #expect(VoiceRanking.needsBetterVoice(all) == false, "the banner must no longer be warranted")
    }

    @Test("without Ava the banner is warranted again")
    func withoutAvaBannerReturns() {
        #expect(VoiceRanking.needsBetterVoice([Self.samanthaAsInstalled]))
    }
}
