import Foundation
import Testing

@Suite("Scorer")
struct ScorerTests {

    /// Confident transcript, so the verdict does not interfere with accuracy assertions.
    func transcript(_ text: String, confidence: Double = 0.9) -> Transcript {
        let words = Normalizer.tokenize(text, side: .hypothesis).map {
            TranscriptWord(text: $0.normalized, confidence: confidence, startTime: 0, duration: 1)
        }
        return Transcript(text: text, words: words)
    }

    func score(_ reference: String, _ heard: String, confidence: Double = 0.9) -> ScoreReport {
        Scorer.score(reference: reference, transcript: transcript(heard, confidence: confidence))
    }

    func statuses(_ r: ScoreReport) -> [WordStatus] { r.words.map(\.status) }

    // MARK: - The table from the plan

    @Test("a perfect read scores 1.0 with every word matched")
    func perfect() {
        let r = score("the fog came in", "the fog came in")
        #expect(r.accuracy == 1.0)
        #expect(r.matchCount == 4)
        #expect(statuses(r) == [.match, .match, .match, .match])
    }

    @Test("one wrong word is one substitution, the rest match")
    func oneSubstitution() {
        let r = score("the fog came in", "the fog came on")
        #expect(r.substitutionCount == 1)
        #expect(r.matchCount == 3)
        #expect(r.accuracy < 1.0)
    }

    /// The test that proves global alignment rather than greedy matching.
    @Test("a skipped word is missed, and the following words still match")
    func skippedWord() {
        let r = score("the fog came in", "the fog in")
        #expect(r.missedCount == 1)
        #expect(r.matchCount == 3)
        let missed = r.words.first { $0.status == .missed }
        #expect(missed?.normalized == "came")
    }

    @Test("a skipped word mid-sentence does not cascade")
    func skippedMidSentence() {
        let r = score("one two three four five", "one two four five")
        #expect(r.missedCount == 1)
        #expect(r.matchCount == 4)
        #expect(r.words.first { $0.status == .missed }?.normalized == "three")
    }

    @Test("an inserted word is extra, and costs less than a deletion")
    func insertionCheaperThanDeletion() {
        let inserted = score("the fog came in", "the the fog came in")
        let deleted = score("the fog came in", "fog came in")
        #expect(inserted.extraCount == 1)
        #expect(inserted.matchCount == 4)
        #expect(deleted.missedCount == 1)
        #expect(inserted.accuracy > deleted.accuracy,
                "insertion \(inserted.accuracy) should beat deletion \(deleted.accuracy)")
    }

    @Test("a near miss is partial, between a match and a substitution")
    func partialCredit() {
        let partial = score("feet", "feed")
        let exact = score("feet", "feet")
        let wrong = score("feet", "zebra")
        #expect(partial.partialCount == 1)
        #expect(exact.accuracy > partial.accuracy)
        #expect(partial.accuracy > wrong.accuracy)
    }

    @Test("nothing heard scores zero with every word missed")
    func nothingHeard() {
        let r = score("the fog came in", "")
        #expect(r.accuracy == 0.0)
        #expect(r.missedCount == 4)
        #expect(statuses(r).allSatisfy { $0 == .missed })
    }

    @Test("an empty reference and an empty transcript scores 1.0")
    func bothEmpty() {
        let r = score("", "")
        #expect(r.accuracy == 1.0)
        #expect(r.referenceTokenCount == 0)
        #expect(r.accuracy.isFinite)
    }

    /// Revision 1's formula gave negative infinity or NaN here, and its test row asked
    /// only that accuracy be "defined".
    @Test("an empty reference with words heard scores 0.0, all extra")
    func emptyReferenceWithWords() {
        let r = score("", "anything at all")
        #expect(r.accuracy == 0.0)
        #expect(r.accuracy.isFinite)
        #expect(r.extraCount == 3)
        #expect(statuses(r).allSatisfy { $0 == .extra })
    }

    /// Measured at -4.0 before the clamp, which the UI would have shown as "-400%".
    @Test("massive over-insertion floors at zero rather than going negative")
    func overInsertionFloors() {
        let spurious = Array(repeating: "word", count: 40).joined(separator: " ")
        let r = score("the fog came in", "the fog came in " + spurious)
        #expect(r.accuracy >= 0.0, "got \(r.accuracy)")
        #expect(r.accuracy <= 1.0)
        #expect(r.accuracy.isFinite)
        // The signal is preserved rather than discarded by the clamp.
        #expect(r.rawWeightedError > Double(r.referenceTokenCount))
    }

    /// With these costs two insertions tie one substitution, so the tie-break has to be
    /// stated or the flagged word is decided by implementation accident.
    @Test("alignment ties resolve deterministically")
    func tieBreak() {
        let r = score("a", "x y")
        #expect(r.words.filter { $0.status == .substituted }.count == 1)
        #expect(r.words.filter { $0.status == .extra }.count == 1)
        #expect(r.words.first { $0.status == .substituted }?.normalized == "a")
    }

    @Test("a single-token reference does not crash", arguments: ["", "a", "different", "a b c"])
    func singleTokenReference(heard: String) {
        let r = score("one", heard)
        #expect(r.accuracy >= 0.0 && r.accuracy <= 1.0)
        #expect(r.accuracy.isFinite)
    }

    @Test("casing alone does not cost anything")
    func casingIrrelevant() {
        #expect(score("The Fog Came In", "the fog came in").accuracy == 1.0)
    }

    @Test("a transcript that repeats the reference twice does not go negative")
    func doubledTranscript() {
        let r = score("the fog came in", "the fog came in the fog came in")
        #expect(r.accuracy >= 0.0 && r.accuracy <= 1.0)
        #expect(r.extraCount == 4)
    }

    @Test("a repeated word in the reference is aligned, not collapsed")
    func repeatedReferenceWord() {
        let r = score("the the fog", "the the fog")
        #expect(r.accuracy == 1.0)
        #expect(r.matchCount == 3)
    }

    @Test("digits and their spelled forms match either way round")
    func digitsMatch() {
        #expect(score("I have 3 apples", "i have three apples").accuracy == 1.0)
        #expect(score("I have three apples", "i have 3 apples").accuracy == 1.0)
    }

    @Test("contractions match their expansion")
    func contractionsMatch() {
        #expect(score("I don't know", "i do not know").accuracy == 1.0)
    }

    @Test("filler words in the transcript are not penalized")
    func fillersFree() {
        #expect(score("the fog came in", "um the fog uh came in").accuracy == 1.0)
    }

    @Test("a paragraph-scale reference scores correctly and quickly")
    func paragraphScale() {
        let sentence = "the quick brown fox jumps over the lazy dog "
        let reference = String(repeating: sentence, count: 33)  // ~300 tokens
        let start = Date()
        let r = score(reference, reference)
        let elapsed = Date().timeIntervalSince(start)
        #expect(r.accuracy == 1.0)
        #expect(r.referenceTokenCount > 250, "got \(r.referenceTokenCount)")
        #expect(elapsed < 3.0, "took \(elapsed)s")
    }

    @Test("a reference beyond the token cap is refused rather than aligned")
    func tokenCapRefused() {
        let huge = String(repeating: "word ", count: Scorer.maxReferenceTokens + 50)
        let r = score(huge, "word")
        #expect(r.accuracy == 0.0)
        #expect(r.referenceTokenCount > Scorer.maxReferenceTokens)
        #expect(r.accuracy.isFinite)
    }

    // MARK: - Word error rate

    @Test("word error rate matches the classic unit-cost formula")
    func werFormula() {
        let r = score("one two three four", "one two four")
        let expected = Double(r.substitutionCount + r.missedCount + r.extraCount) / Double(r.referenceTokenCount)
        #expect(abs(r.wordErrorRate - expected) < 1e-12)
    }

    @Test("word error rate is zero on a perfect read")
    func werPerfect() {
        #expect(score("the fog came in", "the fog came in").wordErrorRate == 0.0)
    }

    // MARK: - The honesty constraint, in all four quadrants

    @Test("low confidence and low accuracy reads as hard to hear")
    func hardToHear() {
        let r = score("the fog came in on little cat feet", "mumble", confidence: 0.1)
        #expect(r.verdict == .hardToHear)
    }

    @Test("low confidence but decent accuracy shows the score with a note")
    func someWordsHardToHear() {
        let r = score("the fog came in", "the fog came in", confidence: 0.1)
        #expect(r.verdict == .someWordsHardToHear)
        #expect(r.accuracy == 1.0)
    }

    /// Clearly reading the wrong words must still show a low score. Suppressing it would
    /// destroy the feature's purpose.
    @Test("high confidence and low accuracy still shows the low score")
    func confidentlyWrong() {
        let r = score("the fog came in", "completely different words entirely", confidence: 0.95)
        #expect(r.verdict == .clear)
        #expect(r.accuracy < 0.5)
    }

    @Test("high confidence and high accuracy is clear")
    func clearAndCorrect() {
        #expect(score("the fog came in", "the fog came in", confidence: 0.95).verdict == .clear)
    }

    @Test("a transcript far longer than the reference reads as hard to hear, not as a bad score")
    func runawayTranscript() {
        let noise = Array(repeating: "noise", count: 30).joined(separator: " ")
        let r = score("the fog", noise, confidence: 0.9)
        #expect(r.verdict == .hardToHear)
    }

    @Test("the thresholds are named constants, not magic numbers")
    func thresholdsNamed() {
        #expect(Normalizer.partialMatchThreshold == 0.72)
        #expect(Normalizer.lowConfidenceThreshold == 0.30)
        #expect(Normalizer.lowAccuracyThreshold == 0.50)
    }

    // MARK: - Properties over randomized input
    //
    // The invariants. These must never move during item 11's calibration; if tuning would
    // break one, the tuning is wrong.

    static let vocabulary = ["the", "fog", "came", "in", "on", "little", "cat", "feet",
                             "harbor", "city", "three", "3", "don't", "well-known", ""]

    static func randomPairs(count: Int, seed: UInt64) -> [(String, String)] {
        var state = seed
        func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(max(bound, 1)))
        }
        return (0..<count).map { _ in
            let refLen = next(8)
            let hypLen = next(10)
            let ref = (0..<refLen).map { _ in vocabulary[next(vocabulary.count)] }.joined(separator: " ")
            let hyp = (0..<hypLen).map { _ in vocabulary[next(vocabulary.count)] }.joined(separator: " ")
            return (ref, hyp)
        }
    }

    @Test("accuracy is always within zero and one and always finite")
    func accuracyAlwaysInRange() {
        for (ref, hyp) in Self.randomPairs(count: 400, seed: 0xC0FFEE) {
            let r = score(ref, hyp)
            #expect(r.accuracy >= 0.0, "ref=\(ref) hyp=\(hyp) got \(r.accuracy)")
            #expect(r.accuracy <= 1.0, "ref=\(ref) hyp=\(hyp) got \(r.accuracy)")
            #expect(r.accuracy.isFinite, "ref=\(ref) hyp=\(hyp)")
            #expect(!r.accuracy.isNaN, "ref=\(ref) hyp=\(hyp)")
        }
    }

    @Test("word error rate is always within zero and one and always finite")
    func werAlwaysInRange() {
        for (ref, hyp) in Self.randomPairs(count: 400, seed: 0xBEEF) {
            let r = score(ref, hyp)
            #expect(r.wordErrorRate >= 0.0 && r.wordErrorRate <= 1.0, "ref=\(ref) hyp=\(hyp)")
            #expect(r.wordErrorRate.isFinite)
        }
    }

    @Test("the reference-side statuses always account for every reference token")
    func countsAlwaysSum() {
        for (ref, hyp) in Self.randomPairs(count: 400, seed: 0xFEED) {
            let r = score(ref, hyp)
            let sum = r.matchCount + r.partialCount + r.substitutionCount + r.missedCount
            #expect(sum == r.referenceTokenCount,
                    "ref=\(ref) hyp=\(hyp): \(sum) != \(r.referenceTokenCount)")
        }
    }

    @Test("every reference token appears exactly once in the word list, in order")
    func wordListCoversReference() {
        for (ref, hyp) in Self.randomPairs(count: 200, seed: 0x1234) {
            let r = score(ref, hyp)
            let indices = r.words.compactMap(\.targetIndex)
            #expect(indices == Array(0..<r.referenceTokenCount),
                    "ref=\(ref) hyp=\(hyp) got \(indices)")
        }
    }

    @Test("scoring is deterministic")
    func deterministic() {
        for (ref, hyp) in Self.randomPairs(count: 100, seed: 0x5555) {
            let a = score(ref, hyp)
            let b = score(ref, hyp)
            #expect(a.accuracy == b.accuracy)
            #expect(statuses(a) == statuses(b))
        }
    }

    @Test("an identical transcript always scores 1.0")
    func identicalAlwaysPerfect() {
        for (ref, _) in Self.randomPairs(count: 200, seed: 0x7777) where !Normalizer.tokenize(ref).isEmpty {
            let r = score(ref, ref)
            #expect(r.accuracy == 1.0, "ref=\(ref) got \(r.accuracy)")
            #expect(r.missedCount == 0)
            #expect(r.substitutionCount == 0)
        }
    }
}
