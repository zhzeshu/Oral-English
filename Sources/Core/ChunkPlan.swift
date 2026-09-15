import Foundation

/// Plans how to split long audio for recognition.
///
/// Pure, so the timestamp splicing is unit-tested rather than checked by a human reading a
/// list of numbers for monotonicity. Revision 1 designed this at the transcription item and
/// first exercised it two items later, verified only by eye — while warning in its own text
/// that without the offset "the timings silently become useless".
public enum ChunkPlan {

    /// A single recognition request has historically capped out near a minute, and a whole
    /// passage read aloud easily runs to ninety seconds.
    public static let maxChunkSeconds: Double = 45
    /// Below this, one request is fine and simpler.
    public static let singleRequestLimit: Double = 40

    public struct Chunk: Sendable, Equatable {
        public var start: Double
        public var duration: Double
        public var end: Double { start + duration }

        public init(start: Double, duration: Double) {
            self.start = start
            self.duration = duration
        }
    }

    /// Splits a duration into chunks, preferring the quietest point near each boundary.
    ///
    /// `quietPoints` are offsets in seconds where the audio is at its lowest energy. When
    /// none is near a boundary the split lands on the hard limit, which is worse for the
    /// recognizer but never produces an invalid plan.
    public static func plan(totalDuration: Double, quietPoints: [Double] = []) -> [Chunk] {
        guard totalDuration > 0 else { return [] }
        guard totalDuration > singleRequestLimit else {
            return [Chunk(start: 0, duration: totalDuration)]
        }

        var chunks: [Chunk] = []
        var cursor: Double = 0
        let sorted = quietPoints.sorted()

        while cursor < totalDuration {
            let remaining = totalDuration - cursor
            if remaining <= maxChunkSeconds {
                chunks.append(Chunk(start: cursor, duration: remaining))
                break
            }
            let hardLimit = cursor + maxChunkSeconds
            // Prefer a quiet point in the last third of the window.
            let windowStart = cursor + maxChunkSeconds * 0.66
            let candidate = sorted.last { $0 > windowStart && $0 < hardLimit }
            let boundary = candidate ?? hardLimit
            chunks.append(Chunk(start: cursor, duration: boundary - cursor))
            cursor = boundary
        }
        return chunks
    }

    /// Concatenates per-chunk transcripts, offsetting each chunk's word timings by its
    /// start. Without the offset every chunk's timings restart at zero and the result is
    /// silently meaningless.
    public static func splice(_ pieces: [(chunk: Chunk, transcript: Transcript)]) -> Transcript {
        var words: [TranscriptWord] = []
        var texts: [String] = []

        for piece in pieces.sorted(by: { $0.chunk.start < $1.chunk.start }) {
            let trimmed = piece.transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { texts.append(trimmed) }
            for w in piece.transcript.words {
                words.append(TranscriptWord(
                    text: w.text,
                    confidence: w.confidence,
                    startTime: w.startTime + piece.chunk.start,
                    duration: w.duration
                ))
            }
        }
        return Transcript(text: texts.joined(separator: " "), words: words)
    }
}
