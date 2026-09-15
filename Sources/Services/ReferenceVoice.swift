import Foundation

/// Produces the reference audio for a piece of text.
///
/// The seam exists so a neural voice can be added later as one new file plus a picker
/// entry. It is the one abstraction introduced ahead of its second implementation, and that
/// is justified: a neural voice is a recorded expectation, not a hypothetical.
///
/// Main-actor isolated, because every audio service in this app is. That is the two-domain
/// concurrency rule: `@MainActor` for anything touching AVFoundation or Speech, and one
/// actor for the filesystem. Strict concurrency rejects a nonisolated conformance here, and
/// it is right to.
@MainActor
public protocol ReferenceVoice {

    /// Voices this provider can offer.
    func availableVoices() async -> [VoiceOption]

    /// Speaks now, for immediate playback. `onWord` reports the spoken range in UTF-16
    /// offsets into `text`.
    func speak(
        _ text: String,
        voice: VoiceOption?,
        rate: Double,
        onWord: @escaping @Sendable (Int, Int) -> Void
    ) async throws

    func stop()

    /// Writes the audio to a file, for A/B overlay and for self-contained exports.
    func bake(_ text: String, voice: VoiceOption?, rate: Double, to url: URL) async throws

    /// **Whether text leaves this machine.** Non-defaulted on purpose.
    ///
    /// Local-only is a hard requirement, enforced in three places on the recognition side.
    /// Revision 1 left the synthesis side to prose while describing a cloud provider as
    /// costing "one new file plus a picker entry" — so the guarantee would have been
    /// silently violated by exactly the change the plan called cheap. With no default
    /// implementation, every future conformer has to answer, and the compiler enforces it.
    ///
    /// A provider answering true must be off by default, labeled in the picker, require an
    /// explicit one-time opt-in naming what is sent and to whom, and can never be chosen by
    /// the best-installed default.
    var dataLeavesDevice: Bool { get }
}
