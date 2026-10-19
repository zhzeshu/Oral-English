import Foundation
import Testing

@Suite("PermissionMatrix")
struct PermissionMatrixTests {

    @Test("both granted: everything works, no banner")
    func bothGranted() {
        let m = PermissionMatrix(microphone: .granted, recognition: .granted)
        #expect(m.canRecord)
        #expect(m.canScore)
        #expect(m.banner == nil)
        #expect(m.scoringNote == nil)
    }

    @Test("microphone denied: recording off, but reference and existing takes keep working")
    func micDenied() {
        let m = PermissionMatrix(microphone: .denied, recognition: .granted)
        #expect(!m.canRecord)
        #expect(m.canPlayReference, "the app must stay useful")
        #expect(m.canPlayTakes)
        #expect(m.banner == .micDenied)
        #expect(m.isUsable)
    }

    @Test("recognition denied: recording and playback keep working fully, scoring marked off")
    func recognitionDenied() {
        let m = PermissionMatrix(microphone: .granted, recognition: .denied)
        #expect(m.canRecord, "this is the path that keeps the app usable during development")
        #expect(!m.canScore)
        #expect(m.banner == .recognitionDenied)
        #expect(m.scoringNote == "Scoring off")
    }

    @Test("offline model unavailable: scoring off with a message naming en-US")
    func offlineModelMissing() {
        let m = PermissionMatrix(microphone: .granted, recognition: .granted, offlineModelAvailable: false)
        #expect(m.canRecord)
        #expect(!m.canScore, "there is deliberately no server fallback")
        #expect(m.banner == .offlineModelMissing)
        #expect(m.scoringNote?.contains("en-US") == true)
    }

    @Test("both denied: the microphone banner wins, because it is the bigger loss")
    func bothDenied() {
        let m = PermissionMatrix(microphone: .denied, recognition: .denied)
        #expect(m.banner == .micDenied)
        #expect(!m.canRecord)
        #expect(!m.canScore)
        #expect(m.isUsable, "reference playback still works")
    }

    @Test("not determined counts as available, because the request happens on first use")
    func notDetermined() {
        let m = PermissionMatrix(microphone: .notDetermined, recognition: .notDetermined)
        #expect(m.canRecord)
        #expect(m.canScore)
        #expect(m.banner == nil, "nothing prompts or nags at launch")
    }

    @Test("restricted is treated as refused")
    func restricted() {
        let m = PermissionMatrix(microphone: .restricted, recognition: .granted)
        #expect(!m.canRecord)
        #expect(m.banner == .micDenied)
    }

    /// The transition nobody re-tests by hand.
    @Test("a permission revoked after being granted produces the banner again")
    func revokedAfterGrant() {
        var m = PermissionMatrix(microphone: .granted, recognition: .granted)
        #expect(m.banner == nil)
        m.microphone = .denied
        #expect(m.banner == .micDenied)
        m.microphone = .granted
        m.recognition = .denied
        #expect(m.banner == .recognitionDenied)
    }

    @Test("every combination leaves the app usable and produces a defined answer")
    func exhaustive() {
        for mic in PermissionState.allCases {
            for rec in PermissionState.allCases {
                for model in [true, false] {
                    let m = PermissionMatrix(microphone: mic, recognition: rec, offlineModelAvailable: model)
                    #expect(m.isUsable, "mic=\(mic) rec=\(rec) model=\(model)")
                    // canScore must never be true when recognition is refused.
                    if rec.isRefused { #expect(!m.canScore) }
                    if mic.isRefused { #expect(!m.canRecord) }
                    // A banner appears exactly when something is wrong.
                    let somethingWrong = mic.isRefused || rec.isRefused || !model
                    #expect((m.banner != nil) == somethingWrong, "mic=\(mic) rec=\(rec) model=\(model)")
                }
            }
        }
    }

    @Test("banner precedence is strict, so a dismissed nag cannot hide a permission problem")
    func bannerPrecedence() {
        #expect(BannerKind.micDenied < BannerKind.recognitionDenied)
        #expect(BannerKind.recognitionDenied < BannerKind.offlineModelMissing)
        #expect(BannerKind.offlineModelMissing < BannerKind.librarySynced)
        #expect(BannerKind.librarySynced < BannerKind.voiceQuality)
    }

    @Test("permission banners are never dismissible; advisory ones are")
    func dismissibility() {
        #expect(!BannerKind.micDenied.isDismissible)
        #expect(!BannerKind.recognitionDenied.isDismissible)
        #expect(!BannerKind.offlineModelMissing.isDismissible)
        #expect(BannerKind.voiceQuality.isDismissible)
        #expect(BannerKind.librarySynced.isDismissible)
    }
}

/// The distinction the record button depends on.
///
/// Regression cover for "recording is not working": the first tap gated its permission
/// request on `canRecord`, which is true while the microphone is `notDetermined` — so the
/// request never ran in the one state it exists for.
@Suite("PermissionState.needsAsking")
struct PermissionNeedsAskingTests {

    @Test("only the never-asked states are worth asking about")
    func onlyUndetermined() {
        #expect(PermissionState.notDetermined.needsAsking)
        #expect(PermissionState.unknown.needsAsking)
        #expect(!PermissionState.granted.needsAsking)
        #expect(!PermissionState.denied.needsAsking)
        #expect(!PermissionState.restricted.needsAsking)
    }

    @Test("every state is covered, so a new one cannot slip through unclassified")
    func exhaustive() {
        for state in PermissionState.allCases {
            let classified = state.needsAsking || state.isGranted || state.isRefused
            #expect(classified, "\(state) is in none of the three buckets")
        }
    }

    @Test("needsAsking is not the negation of granted, which is the trap")
    func notTheSameAsUngranted() {
        // A refused permission must not be re-requested: the system returns the stored
        // denial without showing anything, so the button appears to do nothing twice.
        #expect(!PermissionState.denied.isGranted)
        #expect(!PermissionState.denied.needsAsking)
    }

    @Test("a notDetermined microphone still reports canRecord, which is why the gate was wrong")
    func canRecordIsNotAReadinessCheck() {
        let fresh = PermissionMatrix(microphone: .notDetermined, recognition: .notDetermined)
        #expect(fresh.canRecord, "notDetermined counts as available by design")
        #expect(fresh.microphone.needsAsking, "so readiness has to be asked separately")
    }
}
