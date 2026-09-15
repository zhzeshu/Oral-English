import Foundation
import Testing

@Suite("Models")
struct ModelsTests {

    static let t0 = ISO8601DateFormatter().date(from: "2026-09-14T20:17:33Z")!

    static func samplePassage() -> Passage {
        let r = SentenceSplitter.split("The fog came in. It sat looking over harbor.\n\nThen it moved on.")
        return Passage(
            title: "The fog came in",
            theme: "Interview prep",
            createdAt: t0,
            updatedAt: t0,
            sourceText: "The fog came in. It sat looking over harbor.\n\nThen it moved on.",
            paragraphs: r.paragraphs,
            sentences: r.sentences
        )
    }

    static func sampleScore() -> ScoreReport {
        ScoreReport(
            accuracy: 0.875, wordErrorRate: 0.125, rawWeightedError: 0.5,
            matchCount: 7, partialCount: 1, substitutionCount: 0, missedCount: 0, extraCount: 0,
            referenceTokenCount: 8,
            transcript: "the fog came in on little cat feed",
            meanConfidence: 0.71, verdict: .clear,
            engine: "SFSpeechRecognizer/onDevice", localeIdentifier: "en-US", scoredAt: t0,
            words: [
                WordResult(targetIndex: 0, display: "The", normalized: "the", heard: "the", status: .match, confidence: 0.95),
                WordResult(targetIndex: 7, display: "feet.", normalized: "feet", heard: "feed", status: .partial, confidence: 0.62),
            ]
        )
    }

    // MARK: - Round trips

    @Test("a passage round-trips through JSON unchanged")
    func passageRoundTrip() throws {
        let p = Self.samplePassage()
        let data = try PassageCoding.encoder().encode(p)
        let back = try PassageCoding.decoder().decode(Passage.self, from: data)
        #expect(back == p)
    }

    @Test("a take with a full score round-trips unchanged")
    func takeRoundTrip() throws {
        let p = Self.samplePassage()
        let take = Take(
            target: .sentence(p.sentences[0].id),
            recordedAt: Self.t0,
            audioPath: "takes/2026-09-14T201733Z-7f3a12.m4a",
            durationSeconds: 3.42,
            referenceText: p.sentences[0].text,
            score: Self.sampleScore()
        )
        let data = try PassageCoding.encoder().encode(take)
        let back = try PassageCoding.decoder().decode(Take.self, from: data)
        #expect(back == take)
    }

    /// Dates are checked by decoding every field and comparing, not by grepping the encoded
    /// text for a literal year. Revision 1 grepped for `"2026-`, which passes when only one
    /// field is ISO 8601 and goes vacuous next year.
    @Test("every date field encodes as ISO 8601 and decodes back exactly")
    func datesAreISO8601() throws {
        let p = Self.samplePassage()
        let data = try PassageCoding.encoder().encode(p)
        let text = String(decoding: data, as: UTF8.self)

        // Both date fields must appear in ISO form, not as bare numbers.
        let isoPattern = try Regex(#"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"#)
        let matches = text.matches(of: isoPattern)
        #expect(matches.count >= 2, "expected createdAt and updatedAt in ISO form, found \(matches.count)")
        #expect(!text.contains("\"createdAt\" : 7"), "a bare numeric date leaked in")

        let back = try PassageCoding.decoder().decode(Passage.self, from: data)
        #expect(back.createdAt == p.createdAt)
        #expect(back.updatedAt == p.updatedAt)
    }

    @Test("stored JSON is human-readable, which is the point of visible storage")
    func jsonIsReadable() throws {
        let data = try PassageCoding.encoder().encode(Self.samplePassage())
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\n"), "expected pretty printing")
        #expect(text.contains("\"title\""))
        // Sorted keys means a diff between two saves is readable.
        let titleIdx = text.range(of: "\"title\"")
        let sentencesIdx = text.range(of: "\"sentences\"")
        #expect(titleIdx != nil && sentencesIdx != nil)
    }

    // MARK: - Schema version

    @Test("a schema version from the future is reported, not crashed on")
    func schemaTooNew() throws {
        var p = Self.samplePassage()
        p.schemaVersion = currentSchemaVersion + 5
        let data = try PassageCoding.encoder().encode(p)
        #expect(throws: AppFailure.self) {
            try PassageCoding.checkSchemaVersion(in: data)
        }
    }

    @Test("a missing schema version is reported")
    func schemaMissing() throws {
        let data = Data(#"{"title":"x"}"#.utf8)
        #expect(throws: AppFailure.self) {
            try PassageCoding.checkSchemaVersion(in: data)
        }
    }

    @Test("malformed JSON is reported as corrupt, not as a crash")
    func schemaMalformed() throws {
        let data = Data("{not json at all".utf8)
        #expect(throws: AppFailure.self) {
            try PassageCoding.checkSchemaVersion(in: data)
        }
    }

    @Test("the current version passes the check")
    func schemaCurrentOK() throws {
        let data = try PassageCoding.encoder().encode(Self.samplePassage())
        try PassageCoding.checkSchemaVersion(in: data)
    }

    /// The migration seam. Retention is unbounded and the schema will change at least once,
    /// so a forward guard with no upgrade path would render a library permanently broken.
    @Test("a version-1 fixture still decodes with the current decoder")
    func v1FixtureDecodes() throws {
        let v1 = """
        {
          "schemaVersion" : 1,
          "createdAt" : "2026-09-14T20:17:33Z",
          "id" : "A1B2C3D4-0000-4000-8000-000000000001",
          "localeIdentifier" : "en-US",
          "paragraphs" : [],
          "sentences" : [],
          "sourceText" : "",
          "title" : "Legacy",
          "updatedAt" : "2026-09-14T20:17:33Z"
        }
        """
        let data = Data(v1.utf8)
        try PassageCoding.checkSchemaVersion(in: data)
        let p = try PassageCoding.decoder().decode(Passage.self, from: data)
        #expect(p.title == "Legacy")
        #expect(p.theme == nil, "an absent optional must decode as nil, not throw")
    }

    // MARK: - Targets

    @Test("target text resolves for all three granularities")
    func targetText() {
        let p = Self.samplePassage()
        #expect(p.text(for: .sentence(p.sentences[0].id)) == p.sentences[0].text)
        #expect(p.text(for: .paragraph(p.paragraphs[0].id)) == p.paragraphs[0].text)
        let whole = p.text(for: .passage(p.id))
        #expect(whole?.contains("\n\n") == true, "whole-passage text joins paragraphs with a blank line")
    }

    @Test("an unknown target id resolves to nil rather than trapping")
    func unknownTarget() {
        let p = Self.samplePassage()
        #expect(p.text(for: .sentence(UUID())) == nil)
        #expect(p.text(for: .passage(UUID())) == nil)
    }

    @Test("a target ref survives a JSON round trip")
    func targetRefRoundTrip() throws {
        let p = Self.samplePassage()
        let ref = TargetRef.sentence(p.sentences[1].id)
        let data = try PassageCoding.encoder().encode(ref)
        let back = try PassageCoding.decoder().decode(TargetRef.self, from: data)
        #expect(back == ref)
        #expect(p.text(for: back) == p.sentences[1].text)
    }

    @Test("allTargets covers every sentence, every paragraph and the passage")
    func allTargets() {
        let p = Self.samplePassage()
        let t = p.allTargets
        #expect(t.count == p.sentences.count + p.paragraphs.count + 1)
        #expect(t.contains(.passage(p.id)))
    }

    // MARK: - Take queries

    static func loaded(withTakes takes: [Take], passage: Passage) -> LoadedPassage {
        LoadedPassage(passage: passage, takes: takes, folderName: "f")
    }

    @Test("takes for a target come back newest first, and only that target's")
    func takesForTarget() {
        let p = Self.samplePassage()
        let a = TargetRef.sentence(p.sentences[0].id)
        let b = TargetRef.sentence(p.sentences[1].id)
        let older = Take(target: a, recordedAt: Self.t0, audioPath: "x", durationSeconds: 1, referenceText: "x")
        let newer = Take(target: a, recordedAt: Self.t0.addingTimeInterval(60), audioPath: "y", durationSeconds: 1, referenceText: "x")
        let other = Take(target: b, recordedAt: Self.t0, audioPath: "z", durationSeconds: 1, referenceText: "x")
        let l = Self.loaded(withTakes: [older, newer, other], passage: p)

        let got = l.takes(for: a)
        #expect(got.count == 2)
        #expect(got.first?.id == newer.id, "newest first")
    }

    @Test("bestTake picks the highest accuracy")
    func bestTake() {
        let p = Self.samplePassage()
        let ref = TargetRef.sentence(p.sentences[0].id)
        func scored(_ acc: Double, _ offset: Double) -> Take {
            var s = Self.sampleScore()
            s.accuracy = acc
            return Take(target: ref, recordedAt: Self.t0.addingTimeInterval(offset),
                        audioPath: "a", durationSeconds: 1, referenceText: "x", score: s)
        }
        let l = Self.loaded(withTakes: [scored(0.61, 0), scored(0.92, 10), scored(0.74, 20)], passage: p)
        #expect(l.bestTake(for: ref)?.score?.accuracy == 0.92)
    }

    @Test("bestTake is nil with no takes and with unscored takes")
    func bestTakeNil() {
        let p = Self.samplePassage()
        let ref = TargetRef.sentence(p.sentences[0].id)
        #expect(Self.loaded(withTakes: [], passage: p).bestTake(for: ref) == nil)
        let unscored = Take(target: ref, recordedAt: Self.t0, audioPath: "a", durationSeconds: 1, referenceText: "x")
        #expect(Self.loaded(withTakes: [unscored], passage: p).bestTake(for: ref) == nil)
    }

    /// A NaN accuracy must not be selected, and must not be compared. NaN breaks strict
    /// weak ordering, and `-Onone` keeps Swift's ordering preconditions enabled, so a sort
    /// over a NaN would trap rather than merely return the wrong answer.
    @Test("bestTake ignores a non-finite accuracy instead of trapping")
    func bestTakeIgnoresNaN() {
        let p = Self.samplePassage()
        let ref = TargetRef.sentence(p.sentences[0].id)
        func withAccuracy(_ acc: Double) -> Take {
            var s = Self.sampleScore()
            s.accuracy = acc
            return Take(target: ref, recordedAt: Self.t0, audioPath: "a", durationSeconds: 1, referenceText: "x", score: s)
        }
        let l = Self.loaded(withTakes: [withAccuracy(.nan), withAccuracy(0.5), withAccuracy(.infinity)], passage: p)
        #expect(l.bestTake(for: ref)?.score?.accuracy == 0.5)
    }

    @Test("problem words list missed and substituted words, de-duplicated, in order")
    func problemWords() {
        var s = Self.sampleScore()
        s.words = [
            WordResult(targetIndex: 0, display: "The", normalized: "the", heard: "the", status: .match),
            WordResult(targetIndex: 1, display: "harbor", normalized: "harbor", heard: "harbour", status: .substituted),
            WordResult(targetIndex: 2, display: "city", normalized: "city", heard: nil, status: .missed),
            WordResult(targetIndex: 3, display: "Harbor", normalized: "harbor", heard: nil, status: .missed),
            WordResult(targetIndex: nil, display: "sitting", normalized: "sitting", heard: "sitting", status: .extra),
        ]
        #expect(s.problemWords == ["harbor", "city"], "case-insensitive de-duplication, reading order, no extras")
    }

    // MARK: - Transcript

    @Test("mean confidence is duration-weighted")
    func meanConfidenceWeighted() {
        let t = Transcript(text: "a b", words: [
            TranscriptWord(text: "a", confidence: 1.0, startTime: 0, duration: 3),
            TranscriptWord(text: "b", confidence: 0.0, startTime: 3, duration: 1),
        ])
        #expect(abs(t.meanConfidence - 0.75) < 0.0001)
    }

    @Test("mean confidence handles no words and zero durations without dividing by zero")
    func meanConfidenceDegenerate() {
        #expect(Transcript(text: "").meanConfidence == 0)
        let zeroDur = Transcript(text: "a", words: [
            TranscriptWord(text: "a", confidence: 0.4, startTime: 0, duration: 0),
            TranscriptWord(text: "b", confidence: 0.6, startTime: 0, duration: 0),
        ])
        #expect(abs(zeroDur.meanConfidence - 0.5) < 0.0001)
        #expect(zeroDur.meanConfidence.isFinite)
    }
}
