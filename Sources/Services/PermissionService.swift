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
    ///
    /// Does **not** update `offlineModelAvailable`: the only trustworthy check for that is
    /// `AssetInventory.status`, which is async. Call `refreshModelAvailability()` alongside
    /// this wherever an async context is available.
    public func refresh() {
        microphone = Self.map(AVAudioApplication.shared.recordPermission)
        recognition = Self.map(SFSpeechRecognizer.authorizationStatus())
    }

    /// Whether the on-device model is actually installed.
    ///
    /// Separate from `refresh()` because it must be async, and worth the split: this value
    /// drives `canScore` and the missing-model banner, and the signal it used to come from
    /// —`SFSpeechRecognizer.supportsOnDeviceRecognition`— was measured returning `true` on
    /// 2026-09-15 while no model was installed and nothing could transcribe. The app would
    /// have promised scoring and then failed at score time.
    public func refreshModelAvailability() async {
        offlineModelAvailable = await TranscriberService.modelStatus() == .installed
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
        await refreshModelAvailability()
        return matrix
    }

    static func requestRecognition() async -> PermissionState {
        await withCheckedContinuation { continuation in
            // The callback arrives off the main thread -- specifically on TCC's XPC reply
            // queue -- so map to a Sendable value inside it and let the continuation carry
            // that across.
            //
            // `map` MUST stay `nonisolated`. This class is `@MainActor`, and that
            // propagates to its static members, so an isolated `map` made this closure
            // assert its executor and the process died with SIGTRAP inside
            // __TCCAccessRequest_block_invoke -- before any status could be stored. The
            // crash is invisible to `test.sh`, because this file imports Speech and so
            // cannot be in the pure test target.
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: map(status))
            }
        }
    }

    /// Legacy capability flag. **Not** a statement that recognition will work.
    ///
    /// Kept only because the permission probe reports it for comparison. Do not gate
    /// behaviour on it — see `refreshModelAvailability()`.
    static func onDeviceRecognitionAvailable() -> Bool {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { return false }
        return recognizer.supportsOnDeviceRecognition
    }

    nonisolated static func map(_ status: AVAudioApplication.recordPermission) -> PermissionState {
        switch status {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .notDetermined
        @unknown default: return .unknown
        }
    }

    nonisolated static func map(_ status: SFSpeechRecognizerAuthorizationStatus) -> PermissionState {
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
