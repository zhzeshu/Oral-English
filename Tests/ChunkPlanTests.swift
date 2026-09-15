import Foundation
import Testing

@Suite("AudioLevel")
struct AudioLevelTests {

    @Test("decibels map to zero through one", arguments: [
        (-160.0, 0.0), (-60.0, 0.0), (-30.0, 0.5), (0.0, 1.0), (10.0, 1.0),
    ] as [(Double, Double)])
    func mapping(decibels: Double, expected: Double) {
        #expect(abs(AudioLevel.normalized(decibels: decibels) - expected) < 0.001)
    }

    /// A nonsensical reading reads as silent rather than as full. Drawing a full meter on
    /// garbage input would say "the microphone is working" at exactly the moment it is not,
    /// which is the opposite of what the meter is for.
    @Test("a non-finite reading reads as silent, not as full")
    func nonFinite() {
        #expect(AudioLevel.normalized(decibels: .nan) == 0)
        #expect(AudioLevel.normalized(decibels: -.infinity) == 0)
        #expect(AudioLevel.normalized(decibels: .infinity) == 0)
    }

    @Test("the level is always within range for any input")
    func alwaysInRange() {
        for db in stride(from: -200.0, through: 40.0, by: 0.5) {
            let v = AudioLevel.normalized(decibels: db)
            #expect(v >= 0 && v <= 1, "db=\(db) gave \(v)")
            #expect(v.isFinite)
        }
    }

    @Test("silence detection catches a dead or muted microphone")
    func silenceDetection() {
        #expect(AudioLevel.isEffectivelySilent(0))
        #expect(AudioLevel.isEffectivelySilent(0.01))
        #expect(!AudioLevel.isEffectivelySilent(0.2))
        #expect(AudioLevel.isEffectivelySilent(AudioLevel.normalized(decibels: -60)))
    }
}

@Suite("ChunkPlan")
struct ChunkPlanTests {

    @Test("short audio is one chunk, no splitting")
    func shortAudio() {
        let chunks = ChunkPlan.plan(totalDuration: 30)
        #expect(chunks.count == 1)
        #expect(chunks[0].start == 0)
        #expect(chunks[0].duration == 30)
    }

    @Test("zero or negative duration yields no chunks")
    func degenerateDuration() {
        #expect(ChunkPlan.plan(totalDuration: 0).isEmpty)
        #expect(ChunkPlan.plan(totalDuration: -5).isEmpty)
    }

    @Test("a ninety-second recording splits into chunks within the limit")
    func ninetySeconds() {
        let chunks = ChunkPlan.plan(totalDuration: 90)
        #expect(chunks.count > 1)
        for c in chunks {
            #expect(c.duration <= ChunkPlan.maxChunkSeconds + 0.001, "chunk of \(c.duration)s")
            #expect(c.duration > 0)
        }
    }

    @Test("chunks are contiguous and cover the whole duration", arguments: [50.0, 90.0, 120.0, 300.0])
    func contiguousCoverage(total: Double) {
        let chunks = ChunkPlan.plan(totalDuration: total)
        #expect(chunks.first?.start == 0)
        #expect(abs((chunks.last?.end ?? 0) - total) < 0.001)
        for (a, b) in zip(chunks, chunks.dropFirst()) {
            #expect(abs(a.end - b.start) < 0.001, "gap between \(a) and \(b)")
        }
    }

    @Test("a quiet point near the boundary is preferred over the hard limit")
    func prefersQuietPoint() {
        let chunks = ChunkPlan.plan(totalDuration: 90, quietPoints: [41.5])
        #expect(chunks.first?.duration == 41.5, "expected the split at the quiet point")
    }

    @Test("a boundary with no nearby quiet point still produces a valid plan")
    func noQuietPoint() {
        let chunks = ChunkPlan.plan(totalDuration: 90, quietPoints: [2.0, 5.0])
        #expect(chunks.count > 1)
        #expect(chunks.first?.duration == ChunkPlan.maxChunkSeconds)
        #expect(abs((chunks.last?.end ?? 0) - 90) < 0.001)
    }

    @Test("planning terminates rather than looping on awkward input", arguments: [
        45.001, 45.5, 89.9, 90.0, 90.1, 135.0, 1000.0,
    ])
    func terminates(total: Double) {
        let chunks = ChunkPlan.plan(totalDuration: total)
        #expect(!chunks.isEmpty)
        #expect(chunks.count < 100, "suspiciously many chunks for \(total)s")
    }

    // MARK: - Splicing

    func words(_ specs: [(String, Double)]) -> [TranscriptWord] {
        specs.map { TranscriptWord(text: $0.0, confidence: 0.8, startTime: $0.1, duration: 0.3) }
    }

    /// The bug the plan feared: every chunk's timings restart at zero.
    @Test("splicing offsets each chunk's timings by its start")
    func splicingOffsets() {
        let spliced = ChunkPlan.splice([
            (ChunkPlan.Chunk(start: 0, duration: 45), Transcript(text: "first part", words: words([("first", 1.0), ("part", 2.0)]))),
            (ChunkPlan.Chunk(start: 45, duration: 45), Transcript(text: "second part", words: words([("second", 1.0), ("part", 2.0)]))),
        ])
        #expect(spliced.words.map(\.startTime) == [1.0, 2.0, 46.0, 47.0])
        #expect(spliced.text == "first part second part")
    }

    @Test("spliced timings increase monotonically across every boundary")
    func monotonic() {
        let pieces = (0..<4).map { i in
            (ChunkPlan.Chunk(start: Double(i) * 45, duration: 45),
             Transcript(text: "chunk \(i)", words: self.words([("a", 1.0), ("b", 20.0), ("c", 44.0)])))
        }
        let spliced = ChunkPlan.splice(pieces)
        let starts = spliced.words.map(\.startTime)
        for (a, b) in zip(starts, starts.dropFirst()) {
            #expect(a < b, "timings went backwards: \(a) then \(b)")
        }
    }

    @Test("pieces arriving out of order are spliced in time order")
    func outOfOrder() {
        let spliced = ChunkPlan.splice([
            (ChunkPlan.Chunk(start: 45, duration: 45), Transcript(text: "second", words: words([("second", 0.5)]))),
            (ChunkPlan.Chunk(start: 0, duration: 45), Transcript(text: "first", words: words([("first", 0.5)]))),
        ])
        #expect(spliced.text == "first second")
        #expect(spliced.words.map(\.startTime) == [0.5, 45.5])
    }

    @Test("an empty chunk does not break the splice")
    func emptyChunk() {
        let spliced = ChunkPlan.splice([
            (ChunkPlan.Chunk(start: 0, duration: 45), Transcript(text: "heard this", words: words([("heard", 1.0)]))),
            (ChunkPlan.Chunk(start: 45, duration: 45), Transcript(text: "", words: [])),
            (ChunkPlan.Chunk(start: 90, duration: 20), Transcript(text: "and this", words: words([("and", 1.0)]))),
        ])
        #expect(spliced.text == "heard this and this")
        #expect(spliced.words.map(\.startTime) == [1.0, 91.0])
    }

    @Test("splicing nothing yields an empty transcript")
    func spliceNothing() {
        let spliced = ChunkPlan.splice([])
        #expect(spliced.text.isEmpty)
        #expect(spliced.words.isEmpty)
    }

    @Test("confidence survives splicing, because the scorer depends on it")
    func confidenceSurvives() {
        let spliced = ChunkPlan.splice([
            (ChunkPlan.Chunk(start: 0, duration: 45),
             Transcript(text: "a", words: [TranscriptWord(text: "a", confidence: 0.42, startTime: 1, duration: 1)])),
        ])
        #expect(spliced.words.first?.confidence == 0.42)
        #expect(spliced.meanConfidence == 0.42)
    }
}
