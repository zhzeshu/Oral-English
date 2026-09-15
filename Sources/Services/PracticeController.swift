import Foundation
import Observation

/// Sequences the audio hardware and owns what is happening right now.
///
/// **Two axes, not one.** Revision 1 of the plan had a single exclusive enum including
/// `scoring`, which would have blocked the next sentence while a take scored — contradicting
/// its own requirement that the UI stay responsive during scoring — and omitted baking
/// entirely, which is a third long non-audio activity.
///
/// - `audio` is genuinely exclusive, because there is one input and one output device. This
///   is what structurally prevents recording while the reference is playing, which is what
///   stops the recognizer transcribing the reference instead of the user.
/// - `inFlight` is background work per target: scoring, baking. Concurrent by design.
@Observable
@MainActor
public final class PracticeController {

    // (AudioActivity is a top-level Core type; no alias needed.)

    public private(set) var audio: AudioActivity = .idle
    public private(set) var inFlight: Set<TargetRef> = []

    /// UTF-16 offsets into the text currently being spoken, for word highlighting.
    public private(set) var spokenRange: (location: Int, length: Int)?
    public private(set) var speakingTarget: TargetRef?

    /// Live input level, 0 to 1, while recording.
    public private(set) var inputLevel: Double = 0

    public var lastError: AppFailure?

    private let voice: any ReferenceVoice

    /// Takes the voice and rate per call rather than holding a settings object.
    ///
    /// `Settings` lives in the app layer, and a service reaching up into it is a layering
    /// violation that showed up immediately: the probe build compiles Core and Services
    /// only, so it failed to find the type. Passing values keeps the dependency pointing
    /// one way.
    public init(voice: any ReferenceVoice) {
        self.voice = voice
    }

    // MARK: - Gating

    public func canRecord(_ matrix: PermissionMatrix) -> Bool {
        matrix.canRecord && audio.isIdle
    }

    public func canPlayReference() -> Bool { audio.isIdle }

    public func isScoring(_ ref: TargetRef) -> Bool { inFlight.contains(ref) }

    // MARK: - Reference playback

    /// Speaks one sentence per utterance, always.
    ///
    /// That keeps highlight ranges local to a sentence, and it is what makes two-level
    /// highlighting at paragraph and whole level fall out rather than needing a new
    /// mechanism. The sequencer below is the other half of that decision.
    public func playReference(
        _ ref: TargetRef,
        sentences: [String],
        voice selected: VoiceOption?,
        rate: Double
    ) async {
        guard audio.isIdle else { return }
        audio = .speaking(ref)
        speakingTarget = ref
        defer {
            audio = .idle
            speakingTarget = nil
            spokenRange = nil
        }

        for sentence in sentences {
            guard case .speaking = audio else { return }
            do {
                try await voice.speak(sentence, voice: selected, rate: rate) { [weak self] location, length in
                    Task { @MainActor in
                        self?.spokenRange = (location, length)
                    }
                }
            } catch let failure as AppFailure {
                Log.failure(Log.audio, failure, context: "speak")
                lastError = failure
                return
            } catch {
                Log.unexpected(Log.audio, error, context: "speak")
                return
            }
            spokenRange = nil
        }
    }

    // MARK: - Recording
    //
    // The controller owns the exclusive audio axis; it does not own the recorder. Starting
    // and stopping the hardware stays with `AppModel`, because stopping a take is not just
    // a state change -- the file has to be adopted into the library and scored, and a
    // controller that reached into the store would point the dependency the wrong way.

    /// Claims the audio axis for recording. False when something else already holds it,
    /// which is what structurally prevents recording over the reference playing.
    public func beginRecording(_ ref: TargetRef) -> Bool {
        guard audio.isIdle else { return false }
        audio = .recording(ref)
        inputLevel = 0
        return true
    }

    /// Releases the audio axis. Safe to call when nothing was recording.
    public func finishRecording() {
        if case .recording = audio { audio = .idle }
        inputLevel = 0
    }

    /// The target currently being recorded, if any.
    public var recordingTarget: TargetRef? {
        if case .recording(let ref) = audio { return ref }
        return nil
    }

    /// Stops reference playback and clears the axis.
    ///
    /// Deliberately does **not** stop the recorder: a recording in progress has a file that
    /// must be finalized and adopted, so it is stopped through `AppModel.stopAudio()`
    /// instead. Calling this while recording would strand the take in `incoming/`.
    public func stopAll() {
        voice.stop()
        audio = .idle
        speakingTarget = nil
        spokenRange = nil
        inputLevel = 0
    }

    // MARK: - Background work

    public func beginBackgroundWork(_ ref: TargetRef) { inFlight.insert(ref) }
    public func endBackgroundWork(_ ref: TargetRef) { inFlight.remove(ref) }

    /// A short delay after synthesis before arming the recorder, so the tail of the
    /// reference does not bleed into the take.
    public static let postSynthesisSettle = Duration.milliseconds(250)
}
