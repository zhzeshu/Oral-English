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
        engine: String = "test",
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
                verdict: verdict(accuracy: accuracy, meanConfidence: meanConfidence),
                engine: engine, localeIdentifier: localeIdentifier,
                scoredAt: scoredAt, words: words
            )
        }

        if n > maxReferenceTokens {
            return ScoreReport(
                accuracy: 0, wordErrorRate: 1, rawWeightedError: Double(n),
                matchCount: 0, partialCount: 0, substitutionCount: 0,
                missedCount: n, extraCount: 0, referenceTokenCount: n,
                transcript: transcriptText, meanConfidence: meanConfidence,
                verdict: .hardToHear,
                engine: engine, localeIdentifier: localeIdentifier,
                scoredAt: scoredAt, words: []
            )
        }

        let ops = align(referenceTokens, hypothesisTokens, costs: costs)
        var words: [WordResult] = []
        var matches = 0, partials = 0, subs = 0, missed = 0, extras = 0
        var weighted = 0.0

        for op in ops {
            switch op {
            case .match(let r, let h):
                matches += 1
                weighted += costs.match
                words.append(WordResult(
                    targetIndex: r, display: referenceTokens[r].display,
                    normalized: referenceTokens[r].normalized,
                    heard: hypothesisTokens[h].normalized, status: .match))
            case .partial(let r, let h):
                partials += 1
                weighted += costs.partial
                words.append(WordResult(
                    targetIndex: r, display: referenceTokens[r].display,
                    normalized: referenceTokens[r].normalized,
                    heard: hypothesisTokens[h].normalized, status: .partial))
            case .substitute(let r, let h):
                subs += 1
                weighted += costs.substitution
                words.append(WordResult(
                    targetIndex: r, display: referenceTokens[r].display,
                    normalized: referenceTokens[r].normalized,
                    heard: hypothesisTokens[h].normalized, status: .substituted))
            case .delete(let r):
                missed += 1
                weighted += costs.deletion
                words.append(WordResult(
                    targetIndex: r, display: referenceTokens[r].display,
                    normalized: referenceTokens[r].normalized,
                    heard: nil, status: .missed))
            case .insert(let h):
                extras += 1
                weighted += costs.insertion
                words.append(WordResult(
                    targetIndex: nil, display: hypothesisTokens[h].display,
                    normalized: hypothesisTokens[h].normalized,
                    heard: hypothesisTokens[h].normalized, status: .extra))
            }
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

        // Which diagonal move applies for each cell, and what it costs.
        enum Diag { case match, partial, substitute }
        var cost = [[Double]](repeating: [Double](repeating: 0, count: m + 1), count: n + 1)
        var back = [[Op?]](repeating: [Op?](repeating: nil, count: m + 1), count: n + 1)

        for i in 1...max(n, 1) where n > 0 {
            cost[i][0] = cost[i - 1][0] + costs.deletion
            back[i][0] = .delete(ref: i - 1)
        }
        for j in 1...max(m, 1) where m > 0 {
            cost[0][j] = cost[0][j - 1] + costs.insertion
            back[0][j] = .insert(hyp: j - 1)
        }

        guard n > 0 && m > 0 else {
            return traceback(back, n: n, m: m)
        }

        for i in 1...n {
            for j in 1...m {
                let sim = Normalizer.similarity(ref[i - 1], hyp[j - 1])
                let diag: Diag
                let diagCost: Double
                if sim >= 1.0 {
                    diag = .match
                    diagCost = costs.match
                } else if sim >= Normalizer.partialMatchThreshold {
                    diag = .partial
                    diagCost = costs.partial
                } else {
                    diag = .substitute
                    diagCost = costs.substitution
                }

                let fromDiag = cost[i - 1][j - 1] + diagCost
                let fromUp = cost[i - 1][j] + costs.deletion     // reference word not heard
                let fromLeft = cost[i][j - 1] + costs.insertion  // heard word not in reference

                // Tie-break: diagonal first, then deletion, then insertion. Combined with
                // the diagonal's own ordering this gives match > partial > substitute >
                // delete > insert.
                var best = fromDiag
                var op: Op
                switch diag {
                case .match: op = .match(ref: i - 1, hyp: j - 1)
                case .partial: op = .partial(ref: i - 1, hyp: j - 1)
                case .substitute: op = .substitute(ref: i - 1, hyp: j - 1)
                }

                if fromUp < best {
                    best = fromUp
                    op = .delete(ref: i - 1)
                }
                if fromLeft < best {
                    best = fromLeft
                    op = .insert(hyp: j - 1)
                }

                cost[i][j] = best
                back[i][j] = op
            }
        }

        return traceback(back, n: n, m: m)
    }

    /// Walks the backpointers and returns operations in reference order, with inserted
    /// words spliced in at the position they were heard.
    static func traceback(_ back: [[Op?]], n: Int, m: Int) -> [Op] {
        var out: [Op] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            guard let op = back[i][j] else { break }
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
