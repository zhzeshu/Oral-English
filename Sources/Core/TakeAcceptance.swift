import Foundation

/// What to do with a recording that has just been finalized.
///
/// Pure and in `Core/` so it is unit-tested, because every branch here is a silent failure
/// if it is wrong. The specific trap this exists to avoid: a take where the microphone
/// heard nothing transcribes to an empty string, which the scorer correctly reports as 0%.
/// Shown as a score, that reads as "your pronunciation is terrible" when it means "your
/// microphone is muted". So a take with no input is kept but deliberately **not scored**,
/// and says why.
public enum TakeAcceptance: Equatable, Sendable {

    /// Keep the audio and score it.
    case score

    /// Keep the audio, skip scoring: a score would be misleading rather than merely low.
    case keepWithoutScoring(NotScoredReason)

    /// There is nothing usable on disk.
    case discard(DiscardReason)

    public enum NotScoredReason: Equatable, Sendable {
        case noInput
        case tooQuiet

        /// Shown in place of a percentage. Names the likely cause, because the user cannot
        /// see their own input level after the fact.
        public var note: String {
            switch self {
            case .noInput:
                return "No sound reached the microphone. Check it is not muted, then try again."
            case .tooQuiet:
                return "That was too quiet to score. Try again a little closer to the microphone."
            }
        }
    }

    public enum DiscardReason: Equatable, Sendable {
        case tooShort
        case unreadable

        public var note: String {
            switch self {
            case .tooShort:
                return "That was too short to keep. Hold the button while you read the whole line."
            case .unreadable:
                return "The recording could not be read back, so it was not kept."
            }
        }
    }

    /// Below this there is nothing to score: a tap on the record button that immediately
    /// stops should leave no trace rather than an empty take in the history.
    public static let minimumSeconds: Double = 0.5

    /// - Parameters:
    ///   - duration: seconds, as read back from the finalized file rather than from the
    ///     recorder's own clock.
    ///   - peakLevel: the highest normalized level seen during the take, 0 through 1.
    ///   - noInputDetected: the recorder's own sustained-silence verdict.
    ///   - isReadable: whether the finalized file opens as audio.
    ///
    /// Order matters. Unreadable and too-short are checked first because the level of a
    /// file that does not exist means nothing.
    public static func evaluate(
        duration: Double,
        peakLevel: Double,
        noInputDetected: Bool,
        isReadable: Bool
    ) -> TakeAcceptance {
        guard isReadable else { return .discard(.unreadable) }
        guard duration.isFinite, duration >= minimumSeconds else { return .discard(.tooShort) }
        if noInputDetected { return .keepWithoutScoring(.noInput) }
        if !peakLevel.isFinite || AudioLevel.isEffectivelySilent(peakLevel) {
            return .keepWithoutScoring(.tooQuiet)
        }
        return .score
    }
}
