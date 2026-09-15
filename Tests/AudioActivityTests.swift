import Foundation
import Testing

/// The state machine item 08 claims is tested.
///
/// It was not, until the gap audit caught it: the enum lived in `Services`, which the test
/// target does not compile, so the checklist line asserting coverage was false.
@Suite("AudioActivity")
struct AudioActivityTests {

    static let ref = TargetRef.sentence(UUID())
    static let other = TargetRef.sentence(UUID())

    @Test("only idle is idle")
    func idleness() {
        #expect(AudioActivity.idle.isIdle)
        #expect(!AudioActivity.speaking(Self.ref).isIdle)
        #expect(!AudioActivity.recording(Self.ref).isIdle)
        #expect(!AudioActivity.playingTake(UUID()).isIdle)
        #expect(!AudioActivity.playingAB(Self.ref).isIdle)
    }

    @Test("target-bearing states report their target")
    func targets() {
        #expect(AudioActivity.speaking(Self.ref).target == Self.ref)
        #expect(AudioActivity.recording(Self.ref).target == Self.ref)
        #expect(AudioActivity.playingAB(Self.ref).target == Self.ref)
        #expect(AudioActivity.idle.target == nil)
        #expect(AudioActivity.playingTake(UUID()).target == nil)
    }

    /// Idle has no label, which is what makes the status line vanish rather than render an
    /// empty bar.
    @Test("only idle has no label")
    func labels() {
        #expect(AudioActivity.idle.label == nil)
        for state: AudioActivity in [
            .speaking(Self.ref), .recording(Self.ref), .playingTake(UUID()), .playingAB(Self.ref),
        ] {
            #expect(state.label != nil, "\(state) needs a label for the status line")
        }
    }

    @Test("states are distinguishable, including by target")
    func equality() {
        #expect(AudioActivity.speaking(Self.ref) == .speaking(Self.ref))
        #expect(AudioActivity.speaking(Self.ref) != .speaking(Self.other))
        #expect(AudioActivity.speaking(Self.ref) != .recording(Self.ref))
        #expect(AudioActivity.idle != .speaking(Self.ref))
    }

    /// The property the whole design rests on: exactly one thing owns the devices. This is
    /// what makes echo capture impossible rather than merely unlikely.
    @Test("the enum cannot represent two simultaneous activities")
    func exclusivity() {
        let state = AudioActivity.speaking(Self.ref)
        #expect(!state.isIdle, "so a record tap gated on isIdle is refused")
        // There is no case carrying two targets or two activities, by construction.
        #expect(state.target == Self.ref)
    }

    @Test("a take being played is identified by take id, not by target")
    func playingTakeCarriesTakeID() {
        let takeID = UUID()
        let state = AudioActivity.playingTake(takeID)
        #expect(state.target == nil, "a take belongs to a target, but playback is of one take")
        #expect(state == .playingTake(takeID))
        #expect(state != .playingTake(UUID()))
    }
}
