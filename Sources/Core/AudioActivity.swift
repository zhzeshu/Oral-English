import Foundation

/// What the audio hardware is doing right now.
///
/// In `Core/` rather than beside the controller for a specific reason: item 08's checklist
/// claims this state machine is covered by test, and the test target compiles `Core` only.
/// Left in `Services/` the claim would have been false — which the gap audit caught.
///
/// This axis is genuinely exclusive, because there is one input device and one output
/// device. It is what structurally prevents recording while the reference is playing, and
/// therefore what stops the recognizer transcribing the reference instead of the user.
/// Background work such as scoring and baking is deliberately **not** here; it lives on a
/// separate in-flight set, so a take scoring cannot block the next sentence.
public enum AudioActivity: Equatable, Sendable {
    case idle
    case speaking(TargetRef)
    case recording(TargetRef)
    case playingTake(UUID)
    case playingAB(TargetRef)

    public var isIdle: Bool { self == .idle }

    public var target: TargetRef? {
        switch self {
        case .speaking(let r), .recording(let r), .playingAB(let r): return r
        case .idle, .playingTake: return nil
        }
    }

    /// Human-readable, for the transient status line.
    public var label: String? {
        switch self {
        case .idle: return nil
        case .speaking: return "Playing reference"
        case .recording: return "Recording"
        case .playingTake: return "Playing your take"
        case .playingAB: return "Comparing"
        }
    }
}
