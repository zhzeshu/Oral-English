import Foundation
import Observation

/// Knows which voices exist and whether the user needs a better one.
@Observable
@MainActor
public final class VoiceCatalog {

    public private(set) var voices: [VoiceOption] = []
    public private(set) var needsBetterVoice = false

    private let provider: any ReferenceVoice

    public init(provider: any ReferenceVoice) {
        self.provider = provider
    }

    public func refresh() async {
        voices = await provider.availableVoices()
        needsBetterVoice = VoiceRanking.needsBetterVoice(voices)
    }

    /// The user's choice if it is still installed, otherwise the best installed voice.
    /// Never the system default: that is the compact voice this whole item exists to avoid.
    public func resolved(preferred id: String?) -> VoiceOption? {
        VoiceRanking.resolve(preferred: id, from: voices)
    }

    public var grouped: [(tier: VoiceTier, voices: [VoiceOption])] {
        VoiceRanking.grouped(voices)
    }

    /// The three clicks needed, so the banner does not just say "go to settings".
    public static let downloadInstructions = """
    System Settings, then Accessibility, then Spoken Content, then System Voice, then \
    Manage Voices. Tick Ava for a natural American English voice, or Tom for a male voice.
    """
}
