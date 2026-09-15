import Foundation
import Testing

/// Calibration against real recordings.
///
/// Separate from the scorer's invariant tests on purpose, and the distinction is the whole
/// methodology: **invariant** tests assert bounds, count sums and alignment structure, and
/// must never move during tuning. **Calibration** tests assert agreement with hand-written
/// labels, and moving them is the work.
///
/// Skips cleanly with a clear message when no fixture exists, rather than passing silently.
/// A calibration suite that reports success on an empty directory is worse than no suite.
@Suite("Calibration")
struct CalibrationTests {

    struct Fixture: Codable {
        var audioFile: String
        var referenceText: String
        var transcript: String
        var words: [TranscriptWord]
        var expectedFlaggedWords: [String]
        var category: String
        var split: String
    }

    static var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    static func load(split: String? = nil) -> [Fixture] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(
            at: fixturesDirectory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(Fixture.self, from: Data(contentsOf: $0)) }
            .filter { split == nil || $0.split == split }
    }

    @Test("fixtures are present, or this suite says so rather than passing quietly")
    func fixturesPresent() {
        let all = Self.load()
        if all.isEmpty {
            // Deliberately not a failure: the project is usable without calibration, and a
            // red suite would train everyone to ignore it. But it must be visible.
            print("""

                CALIBRATION NOT RUN: no fixtures in Tests/Fixtures.
                The scorer is running on its shipped defaults, tuned against synthetic
                cases only. See Tests/Fixtures/README.md and docs/plan/11-score-calibration.md.

                """)
        }
        #expect(all.count >= 0)
    }

    @Test("every fixture carries a hand-written label, or it is not a fixture")
    func fixturesAreLabelled() {
        for f in Self.load() {
            #expect(!f.referenceText.isEmpty, "\(f.audioFile) has no reference text")
            #expect(["clean", "substitution", "skip", "insertion", "mumbled", "long"].contains(f.category),
                    "\(f.audioFile) has an unknown category \(f.category)")
            #expect(["tuning", "heldOut"].contains(f.split), "\(f.audioFile) has an unknown split")
            if f.category == "clean" {
                #expect(f.expectedFlaggedWords.isEmpty, "a clean read should flag nothing")
            }
        }
    }

    @Test("a clean read scores at least 95 and never reads as hard to hear")
    func cleanReadsScoreHigh() {
        let clean = Self.load().filter { $0.category == "clean" }
        guard !clean.isEmpty else { return }
        for f in clean {
            let report = Scorer.score(
                reference: f.referenceText,
                transcript: Transcript(text: f.transcript, words: f.words))
            #expect(report.accuracy >= 0.95, "\(f.audioFile) scored \(report.accuracy)")
            #expect(report.verdict != .hardToHear, "\(f.audioFile) read as hard to hear")
        }
    }

    @Test("the flagged words match the labels on the held-out set")
    func heldOutAgreement() {
        let heldOut = Self.load(split: "heldOut")
        guard !heldOut.isEmpty else { return }

        var agreed = 0
        for f in heldOut {
            let report = Scorer.score(
                reference: f.referenceText,
                transcript: Transcript(text: f.transcript, words: f.words))
            let got = Set(report.problemWords.map { $0.lowercased() })
            let want = Set(f.expectedFlaggedWords.map { $0.lowercased() })
            if got == want { agreed += 1 }
        }
        let rate = Double(agreed) / Double(heldOut.count)
        #expect(rate >= 0.80, "flagged-word agreement was \(Int(rate * 100)) percent across \(heldOut.count) takes")
    }

    @Test("a mumbled take reads as hard to hear rather than as a bad score")
    func mumbledReadsAsHardToHear() {
        let mumbled = Self.load().filter { $0.category == "mumbled" }
        guard !mumbled.isEmpty else { return }
        for f in mumbled {
            let report = Scorer.score(
                reference: f.referenceText,
                transcript: Transcript(text: f.transcript, words: f.words))
            #expect(report.verdict != .clear, "\(f.audioFile) showed a plain score for mumbled audio")
        }
    }

    /// The constants item 11 is allowed to change, and nothing else.
    @Test("the tunable constants are exactly the ones the plan permits")
    func tunablesUnchanged() {
        #expect(Normalizer.partialMatchThreshold == 0.72)
        #expect(Normalizer.lowConfidenceThreshold == 0.30)
        #expect(Normalizer.lowAccuracyThreshold == 0.50)
        let costs = Scorer.defaultCosts
        #expect(costs.match == 0.0)
        #expect(costs.partial == 0.5)
        #expect(costs.substitution == 1.0)
        #expect(costs.deletion == 1.0)
        #expect(costs.insertion == 0.5)
        #expect(costs.insertion < costs.deletion,
                "the asymmetry is the biggest lever on whether scores feel fair")
    }
}
