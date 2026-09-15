import Foundation
import Testing

@Suite("TakeAcceptance")
struct TakeAcceptanceTests {

    private func evaluate(
        duration: Double = 3.0,
        peak: Double = 0.5,
        noInput: Bool = false,
        readable: Bool = true
    ) -> TakeAcceptance {
        TakeAcceptance.evaluate(
            duration: duration, peakLevel: peak,
            noInputDetected: noInput, isReadable: readable)
    }

    @Test("a normal take is scored")
    func normal() {
        #expect(evaluate() == .score)
    }

    @Test("an unreadable file is discarded regardless of everything else")
    func unreadable() {
        #expect(evaluate(readable: false) == .discard(.unreadable))
        // Checked before duration and level, because neither means anything for a file
        // that cannot be opened.
        #expect(evaluate(duration: 10, peak: 0.9, readable: false) == .discard(.unreadable))
    }

    @Test("a take shorter than the minimum is discarded, not kept empty")
    func tooShort() {
        #expect(evaluate(duration: 0.0) == .discard(.tooShort))
        #expect(evaluate(duration: TakeAcceptance.minimumSeconds - 0.01) == .discard(.tooShort))
    }

    @Test("the minimum is inclusive, so a take exactly at the boundary survives")
    func boundaryIsInclusive() {
        #expect(evaluate(duration: TakeAcceptance.minimumSeconds) == .score)
    }

    @Test("a non-finite duration is discarded rather than trusted")
    func nonFiniteDuration() {
        #expect(evaluate(duration: .nan) == .discard(.tooShort))
        #expect(evaluate(duration: .infinity) == .discard(.tooShort))
    }

    @Test("no input is kept but never scored, because 0% would blame the speaker")
    func noInput() {
        #expect(evaluate(noInput: true) == .keepWithoutScoring(.noInput))
        // The recorder's verdict wins over a peak that looks acceptable: a late spike
        // after three seconds of silence is still a broken take.
        #expect(evaluate(peak: 0.9, noInput: true) == .keepWithoutScoring(.noInput))
    }

    @Test("a take at or below the silence threshold is kept without a score")
    func tooQuiet() {
        #expect(evaluate(peak: 0.0) == .keepWithoutScoring(.tooQuiet))
        #expect(evaluate(peak: AudioLevel.silenceThreshold) == .keepWithoutScoring(.tooQuiet))
        #expect(evaluate(peak: AudioLevel.silenceThreshold + 0.001) == .score)
    }

    @Test("a non-finite peak is treated as silence rather than as a loud take")
    func nonFinitePeak() {
        #expect(evaluate(peak: .nan) == .keepWithoutScoring(.tooQuiet))
    }

    @Test("every reason has a note that says what to do about it")
    func notesAreActionable() {
        let notes = [
            TakeAcceptance.NotScoredReason.noInput.note,
            TakeAcceptance.NotScoredReason.tooQuiet.note,
            TakeAcceptance.DiscardReason.tooShort.note,
            TakeAcceptance.DiscardReason.unreadable.note,
        ]
        for note in notes {
            #expect(!note.isEmpty)
            #expect(note.first!.isUppercase, "reads as a sentence: \(note)")
            #expect(note.hasSuffix("."), "ends as a sentence: \(note)")
        }
        // The two recoverable ones tell the user what to change, not just what happened.
        #expect(TakeAcceptance.NotScoredReason.noInput.note.contains("try again"))
        #expect(TakeAcceptance.NotScoredReason.tooQuiet.note.contains("Try again"))
    }
}
