import Foundation

/// Compares a transcript against the reference and reports which words were recognized.
///
/// Global alignment with backpointers, deliberately not greedy matching and not longest
/// common subsequence: only global alignment attributes insertions and deletions correctly
/// when a word is skipped mid-sentence, which is exactly the case a learner cares about.
public enum Scorer {

    /// Costs, and they are deliberately asymmetric.
    ///
    /// An insertion costs less than a deletion because on-device recognition over-inserts
    /// short function words far more than it drops content words, and skipping a word is a
    /// genuinely worse reading error than the recognizer inventing an "a".
    ///
    /// This table is the single biggest driver of whether scores feel fair rather than
    /// punitive. If the user says scores feel harsh, change these first. Calibrated at
    /// item 11 against real recordings.
    public struct Costs: Sendable, Equatable {
        public var match: Double = 0.0
        public var partial: Double = 0.5
        public var substitution: Double = 1.0
        public var deletion: Double = 1.0
        public var insertion: Double = 0.5

        public init() {}
    }

    public static let defaultCosts = Costs()

    /// Above this reference-token count a single target is refused rather than aligned.
    /// The table is quadratic, so a pathological 5,000-word "sentence" would be 25 million
    /// cells. A few hundred tokens, which is a real whole passage, is fine.
    public static let maxReferenceTokens = 1_200

    // MARK: - Public entry point

    public static func score(
        reference: String,
        transcript: Transcript,
        costs: Costs = defaultCosts,
        engine: String = "SFSpeechRecognizer/onDevice",
        localeIdentifier: String = "en-US",
        scoredAt: Date = Date()
    ) -> ScoreReport {
        let refTokens = Normalizer.tokenize(reference, side: .reference)
        let hypTokens = Normalizer.tokenize(transcript.text, side: .hypothesis)
        return score(
            referenceTokens: refTokens,
            hypothesisTokens: hypTokens,
            meanConfidence: transcript.meanConfidence,
            transcriptText: transcript.text,
            costs: costs,
            engine: engine,
            localeIdentifier: localeIdentifier,
            scoredAt: scoredAt
        )
    }

    public static func score(
        referenceTokens: [Normalizer.Token],
        hypothesisTokens: [Normalizer.Token],
        meanConfidence: Double,
        transcriptText: String,
        costs: Costs = defaultCosts,
        engine: String = "SFSpeechRecognizer/onDevice",
        localeIdentifier: String = "en-US",
        scoredAt: Date = Date()
    ) -> ScoreReport {
        let n = referenceTokens.count
        let m = hypothesisTokens.count

        // Degenerate cases, each with a defined answer rather than a formula that divides
        // by zero. Revision 1's test table asked only that an empty reference be
        // "accuracy defined", and the formula gave negative infinity or NaN.
        if n == 0 {
            let accuracy: Double = m == 0 ? 1.0 : 0.0
            let words = hypothesisTokens.map {
                WordResult(targetIndex: nil, display: $0.display, normalized: $0.normalized,
                           heard: $0.normalized, status: .extra)
            }
            return ScoreReport(
                accuracy: accuracy,
                wordErrorRate: m == 0 ? 0.0 : 1.0,
                rawWeightedError: Double(m) * costs.insertion,
                matchCount: 0, partialCount: 0, substitutionCount: 0,
                missedCount: 0, extraCount: m, referenceTokenCount: 0,
                transcript: transcriptText,
                meanConfidence: meanConfidence,
                // Pass the real counts. Relying on the defaults here skipped the
                // runaway-transcript check entirely, so an empty reference with forty heard
                // words reported a plain zero rather than "hard to hear".
                verdict: verdict(accuracy: accuracy, meanConfidence: meanConfidence,
                                 extraCount: m, referenceTokenCount: 0),
                engine: engine, localeIdentifier: localeIdentifier,
                scoredAt: scoredAt, words: words
            )
        }

        if n > maxReferenceTokens {
            return ScoreReport(
                accuracy: 0, wordErrorRate: 1, rawWeightedError: Double(n),
                matchCount: 0, partialCount: 0, substitutionCount: 0,
                missedCount: n, extraCount: m, referenceTokenCount: n,
                transcript: transcriptText, meanConfidence: meanConfidence,
                verdict: .unsupportedLength,
                engine: engine, localeIdentifier: localeIdentifier,
                scoredAt: scoredAt, words: []
            )
        }

        let ops = align(referenceTokens, hypothesisTokens, costs: costs)
        var words: [WordResult] = []
        var matches = 0, partials = 0, subs = 0, missed = 0, extras = 0
        var weighted = 0.0

        for op in ops {
            // One construction site rather than five near-identical ones.
            let targetIndex: Int?
            let display: String
            let normalized: String
            let heard: String?
            let status: WordStatus

            switch op {
            case .match(let r, let h):
                matches += 1; weighted += costs.match
                targetIndex = r; display = referenceTokens[r].display
                normalized = referenceTokens[r].normalized
                heard = hypothesisTokens[h].normalized; status = .match
            case .partial(let r, let h):
                partials += 1; weighted += costs.partial
                targetIndex = r; display = referenceTokens[r].display
                normalized = referenceTokens[r].normalized
                heard = hypothesisTokens[h].normalized; status = .partial
            case .substitute(let r, let h):
                subs += 1; weighted += costs.substitution
                targetIndex = r; display = referenceTokens[r].display
                normalized = referenceTokens[r].normalized
                heard = hypothesisTokens[h].normalized; status = .substituted
            case .delete(let r):
                missed += 1; weighted += costs.deletion
                targetIndex = r; display = referenceTokens[r].display
                normalized = referenceTokens[r].normalized
                heard = nil; status = .missed
            case .insert(let h):
                extras += 1; weighted += costs.insertion
                targetIndex = nil; display = hypothesisTokens[h].display
                normalized = hypothesisTokens[h].normalized
                heard = hypothesisTokens[h].normalized; status = .extra
            }

            words.append(WordResult(
                targetIndex: targetIndex, display: display, normalized: normalized,
                heard: heard, status: status))
        }

        // Clamped to [0, 1]. The raw weighted error is kept so the over-insertion signal is
        // not lost when accuracy bottoms out. Revision 1 had no clamp, and 40 spurious
        // words against a 4-token reference measured -4.0, which the UI would have shown as
        // "-400%".
        let rawAccuracy = 1.0 - weighted / Double(n)
        let accuracy = min(max(rawAccuracy, 0.0), 1.0)

        // Classic word error rate with unit costs, for comparison with the weighted score.
        let wer = Double(subs + missed + extras) / Double(n)

        return ScoreReport(
            accuracy: accuracy,
            wordErrorRate: min(max(wer, 0.0), 1.0),
            rawWeightedError: weighted,
            matchCount: matches, partialCount: partials, substitutionCount: subs,
            missedCount: missed, extraCount: extras, referenceTokenCount: n,
            transcript: transcriptText,
            meanConfidence: meanConfidence,
            verdict: verdict(accuracy: accuracy, meanConfidence: meanConfidence,
                             extraCount: extras, referenceTokenCount: n),
            engine: engine, localeIdentifier: localeIdentifier,
            scoredAt: scoredAt, words: words
        )
    }

    // MARK: - Honesty constraint

    /// Specified in all four quadrants, so there is no ambiguous middle.
    ///
    /// Revision 1 gave two unnamed thresholds and an empty test-input cell, which made the
    /// rule unimplementable. Bad audio must not look like bad pronunciation, and clearly
    /// reading the wrong words must still show a low score.
    public static func verdict(
        accuracy: Double,
        meanConfidence: Double,
        extraCount: Int = 0,
        referenceTokenCount: Int = 1
    ) -> AudioQualityVerdict {
        // A transcript far longer than the reference means the recognizer heard something
        // other than the reading. Treat it as an audio problem rather than a red score.
        if referenceTokenCount > 0, Double(extraCount) >= Double(referenceTokenCount) * 2 {
            return .hardToHear
        }
        let lowConfidence = meanConfidence < Normalizer.lowConfidenceThreshold
        if lowConfidence && accuracy < Normalizer.lowAccuracyThreshold { return .hardToHear }
        if lowConfidence { return .someWordsHardToHear }
        return .clear
    }

    // MARK: - Alignment

    enum Op: Sendable, Equatable {
        case match(ref: Int, hyp: Int)
        case partial(ref: Int, hyp: Int)
        case substitute(ref: Int, hyp: Int)
        case delete(ref: Int)
        case insert(hyp: Int)
    }

    /// Needleman-Wunsch over token arrays, with an explicit tie-break order.
    ///
    /// The tie-break matters: with these costs two insertions tie one substitution, so
    /// without a stated preference which word gets flagged is decided by implementation
    /// accident. Preference order is match, partial, substitute, delete, insert — which
    /// keeps a misread word attributed to the word the user actually misread.
    static func align(
        _ ref: [Normalizer.Token],
        _ hyp: [Normalizer.Token],
        costs: Costs
    ) -> [Op] {
        let n = ref.count, m = hyp.count
        guard n > 0, m > 0 else {
            // One side empty: the whole of the other side is a single run of deletions or
            // insertions, which needs no table at all.
            if n > 0 { return (0..<n).map { .delete(ref: $0) } }
            if m > 0 { return (0..<m).map { .insert(hyp: $0) } }
            return []
        }

        // Flat storage, indexed i * (m + 1) + j.
        //
        // `[[Double]](repeating: [Double](...), count: n + 1)` gives n + 1 references to
        // one shared inner array, so the first write to each row triggers a copy-on-write
        // allocation. Same complexity, needless churn. Flat is simpler and allocates twice.
        let stride = m + 1
        var cost = [Double](repeating: 0, count: (n + 1) * stride)
        var back = [Op?](repeating: nil, count: (n + 1) * stride)

        for i in 1...n {
            cost[i * stride] = cost[(i - 1) * stride] + costs.deletion
            back[i * stride] = .delete(ref: i - 1)
        }
        for j in 1...m {
            cost[j] = cost[j - 1] + costs.insertion
            back[j] = .insert(hyp: j - 1)
        }

        for i in 1...n {
            for j in 1...m {
                let sim = Normalizer.similarity(ref[i - 1], hyp[j - 1])
                let diagCost: Double
                var op: Op
                if sim >= 1.0 {
                    diagCost = costs.match
                    op = .match(ref: i - 1, hyp: j - 1)
                } else if sim >= Normalizer.partialMatchThreshold {
                    diagCost = costs.partial
                    op = .partial(ref: i - 1, hyp: j - 1)
                } else {
                    diagCost = costs.substitution
                    op = .substitute(ref: i - 1, hyp: j - 1)
                }

                var best = cost[(i - 1) * stride + (j - 1)] + diagCost
                let fromUp = cost[(i - 1) * stride + j] + costs.deletion
                let fromLeft = cost[i * stride + (j - 1)] + costs.insertion

                // Tie-break: diagonal, then deletion, then insertion. Combined with the
                // diagonal's own ordering this gives match > partial > substitute > delete
                // > insert, which is what keeps a misread word attributed to the word the
                // user actually misread.
                if fromUp < best {
                    best = fromUp
                    op = .delete(ref: i - 1)
                }
                if fromLeft < best {
                    best = fromLeft
                    op = .insert(hyp: j - 1)
                }

                cost[i * stride + j] = best
                back[i * stride + j] = op
            }
        }

        return traceback(back, stride: stride, n: n, m: m)
    }

    /// Walks the backpointers and returns operations in reference order, with inserted
    /// words spliced in at the position they were heard.
    static func traceback(_ back: [Op?], stride: Int, n: Int, m: Int) -> [Op] {
        var out: [Op] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            guard let op = back[i * stride + j] else { break }
            out.append(op)
            switch op {
            case .match, .partial, .substitute:
                i -= 1; j -= 1
            case .delete:
                i -= 1
            case .insert:
                j -= 1
            }
        }
        return out.reversed()
    }
}
