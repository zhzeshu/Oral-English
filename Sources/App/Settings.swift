import Foundation
import Observation

/// App-wide preferences.
///
/// Revision 1 of the plan had six requirements needing a settings layer and no owner for
/// any of them: the selected voice and rate had to survive a relaunch, the app defaulted to
/// "the best installed" voice but the user's override needed somewhere to live, the voice
/// banner was first-run-only which needs a flag, and the last selection had to be restored.
/// The detail pane even displayed a voice that no model field stored.
///
/// Voice and rate are **app-wide, not per-passage**. That was the open question; this is
/// the answer.
@Observable
@MainActor
public final class Settings {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.voiceIdentifier = defaults.string(forKey: Keys.voiceIdentifier)
        self.speakingRate = defaults.object(forKey: Keys.speakingRate) as? Double ?? Settings.naturalSpeakingRate
        self.playbackRate = defaults.object(forKey: Keys.playbackRate) as? Double ?? 1.0
        self.voiceBannerDismissed = defaults.bool(forKey: Keys.voiceBannerDismissed)
        self.lastPassageFolder = defaults.string(forKey: Keys.lastPassageFolder)
        self.libraryPathOverride = defaults.string(forKey: Keys.libraryPathOverride)
    }

    enum Keys {
        static let voiceIdentifier = "voiceIdentifier"
        static let speakingRate = "speakingRate"
        static let playbackRate = "playbackRate"
        static let voiceBannerDismissed = "voiceBannerDismissed"
        static let lastPassageFolder = "lastPassageFolder"
        static let libraryPathOverride = "libraryPathOverride"
    }

    /// nil means "use the best installed English voice", which is not the same as the
    /// system default — the system default is the compact voice that makes speech sound
    /// robotic in the first place.
    public var voiceIdentifier: String? {
        didSet { defaults.set(voiceIdentifier, forKey: Keys.voiceIdentifier) }
    }

    /// Slightly below normal, because the reference exists to be imitated.
    /// `AVSpeechUtteranceDefaultSpeechRate`, written as a literal so this file stays free
    /// of AVFoundation and can be compiled by the probe and test builds.
    ///
    /// The old default was 0.45. A premium voice's prosody is tuned at its own rate, and
    /// slowing it stretches the vowels and flattens the intonation -- which is heard as
    /// "mechanical" rather than as "slow". Reverting to the voice's natural rate is the
    /// single biggest change to how Ava sounds.
    public static let naturalSpeakingRate: Double = 0.5

    public var speakingRate: Double {
        didSet { defaults.set(speakingRate, forKey: Keys.speakingRate) }
    }

    public var playbackRate: Double {
        didSet { defaults.set(playbackRate, forKey: Keys.playbackRate) }
    }

    /// Dismissible once, thereafter the prompt lives in the menu. A permanent nag is worse
    /// than a robotic voice.
    public var voiceBannerDismissed: Bool {
        didSet { defaults.set(voiceBannerDismissed, forKey: Keys.voiceBannerDismissed) }
    }

    public var lastPassageFolder: String? {
        didSet { defaults.set(lastPassageFolder, forKey: Keys.lastPassageFolder) }
    }

    /// Set when the user accepts the offer to move the library out of an iCloud-synced
    /// Documents folder.
    public var libraryPathOverride: String? {
        didSet { defaults.set(libraryPathOverride, forKey: Keys.libraryPathOverride) }
    }

    public var libraryRoot: URL {
        if let p = libraryPathOverride { return URL(fileURLWithPath: p, isDirectory: true) }
        return Paths.defaultLibraryRoot()
    }
}
