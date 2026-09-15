import Foundation

public enum PermissionState: String, Codable, Sendable, CaseIterable {
    case unknown
    case notDetermined
    case granted
    case denied
    case restricted

    public var isGranted: Bool { self == .granted }
    public var isRefused: Bool { self == .denied || self == .restricted }
}

/// What the app can do in a given permission state, as a pure function.
///
/// Revision 1 of the plan left this as a four-row table verified by hand. It is
/// `(mic, recognition, offlineModel) -> (canRecord, canScore, banner)`, so it belongs in the
/// test target — nobody will re-test the granted-then-revoked transition by hand in month
/// three, and the whole point of the table is that the app stays useful in every state.
public struct PermissionMatrix: Sendable, Equatable {
    public var microphone: PermissionState
    public var recognition: PermissionState
    /// False when the locale's on-device model is unavailable, including mid-download.
    public var offlineModelAvailable: Bool

    public init(
        microphone: PermissionState,
        recognition: PermissionState,
        offlineModelAvailable: Bool = true
    ) {
        self.microphone = microphone
        self.recognition = recognition
        self.offlineModelAvailable = offlineModelAvailable
    }

    /// Reference playback never depends on a permission.
    public var canPlayReference: Bool { true }

    /// Playback of takes already on disk never depends on a permission either.
    public var canPlayTakes: Bool { true }

    /// Recording needs the microphone. `notDetermined` counts as available, because the
    /// request happens on the first record tap rather than at launch.
    public var canRecord: Bool { !microphone.isRefused }

    /// Scoring needs recognition **and** the offline model. There is deliberately no
    /// server fallback: local-only is a hard requirement, and a silent fallback would
    /// violate it invisibly, which is the class of bug nobody finds.
    public var canScore: Bool { !recognition.isRefused && offlineModelAvailable }

    /// Highest-priority banner for this state, or nil.
    public var banner: BannerKind? {
        if microphone.isRefused { return .micDenied }
        if recognition.isRefused { return .recognitionDenied }
        if !offlineModelAvailable && !recognition.isRefused { return .offlineModelMissing }
        return nil
    }

    /// Whether the app is still worth using. It must never be false.
    public var isUsable: Bool { canPlayReference && canPlayTakes }

    /// Explains the state of scoring in the row detail, so it is marked off rather than
    /// silently absent.
    public var scoringNote: String? {
        if recognition.isRefused { return "Scoring off" }
        if !offlineModelAvailable { return "Scoring needs the offline en-US model" }
        return nil
    }
}
