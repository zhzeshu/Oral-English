import AVFoundation
import Foundation
import Observation
import Speech

/// Microphone and speech-recognition authorization.
///
/// Requested lazily, on the first record tap, never at launch. A cold prompt with no
/// context is the main reason people press Deny, and a denial is expensive to undo.
@Observable
@MainActor
public final class PermissionService {

    public private(set) var microphone: PermissionState = .unknown
    public private(set) var recognition: PermissionState = .unknown
    public private(set) var offlineModelAvailable = true

    /// The recognizer locale is pinned, not taken from the system.
    ///
    /// Verified: `en-GB` and `zh-CN` report available but **not** on-device, and the
    /// never-fall-back rule would then leave such a user with no scoring at all. This is an
    /// American English trainer, so the locale is a product decision.
    public static let locale = Locale(identifier: "en-US")

    public init() {}

    public var matrix: PermissionMatrix {
        PermissionMatrix(
            microphone: microphone,
            recognition: recognition,
            offlineModelAvailable: offlineModelAvailable
        )
    }

    /// Reads current status without touching hardware, so it is safe at launch and on wake.
    public func refresh() {
        microphone = Self.map(AVAudioApplication.shared.recordPermission)
        recognition = Self.map(SFSpeechRecognizer.authorizationStatus())
        offlineModelAvailable = Self.onDeviceRecognitionAvailable()
    }

    /// Requests the microphone, then recognition, both at the moment the user asked for the
    /// feature. Returns what is possible afterwards.
    public func requestForRecording() async -> PermissionMatrix {
        if microphone == .unknown || microphone == .notDetermined {
            let granted = await AVAudioApplication.requestRecordPermission()
            microphone = granted ? .granted : .denied
        }
        if microphone.isGranted, recognition == .unknown || recognition == .notDetermined {
            recognition = await Self.requestRecognition()
        }
        offlineModelAvailable = Self.onDeviceRecognitionAvailable()
        return matrix
    }

    static func requestRecognition() async -> PermissionState {
        await withCheckedContinuation { continuation in
            // The callback arrives off the main thread, so map to a Sendable value inside
            // it and let the continuation carry that across.
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: map(status))
            }
        }
    }

    static func onDeviceRecognitionAvailable() -> Bool {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { return false }
        return recognizer.supportsOnDeviceRecognition
    }

    static func map(_ status: AVAudioApplication.recordPermission) -> PermissionState {
        switch status {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .notDetermined
        @unknown default: return .unknown
        }
    }

    static func map(_ status: SFSpeechRecognizerAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .unknown
        }
    }

    /// Note on `AVAudioSession`: it is unavailable on macOS, and its absence is not the
    /// absence of the problem it solves on iOS. Route-change and interruption events have
    /// to come from Core Audio or `AVCaptureDevice` instead — item 08 does that.
    public func openSettings(for kind: BannerKind) {
        switch kind {
        case .micDenied: Workspace.openPrivacySettings(.microphone)
        case .recognitionDenied, .offlineModelMissing: Workspace.openPrivacySettings(.speechRecognition)
        case .voiceQuality: Workspace.openPrivacySettings(.spokenContent)
        case .librarySynced: break
        }
    }
}
