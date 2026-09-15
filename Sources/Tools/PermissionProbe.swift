import AVFoundation
import Foundation
import Speech

// Reports current permission state and on-device recognition availability. Status only:
// it never requests anything, so running it cannot consume the one chance to prompt well.

@main
struct PermissionProbe {
    @MainActor
    static func main() {
        let service = PermissionService()
        service.refresh()

        print("microphone:            \(service.microphone.rawValue)")
        print("speech recognition:    \(service.recognition.rawValue)")
        print("offline en-US model:   \(service.offlineModelAvailable ? "available" : "NOT available")")

        let m = service.matrix
        print("\nwhat works right now:")
        print("  play reference:  \(m.canPlayReference)")
        print("  play takes:      \(m.canPlayTakes)")
        print("  record:          \(m.canRecord)")
        print("  score:           \(m.canScore)")
        print("  banner:          \(m.banner.map(String.init(describing:)) ?? "none")")
        print("  scoring note:    \(m.scoringNote ?? "none")")

        print("\non-device recognition by locale:")
        for id in ["en-US", "en-GB", "en-AU", "zh-CN"] {
            guard let r = SFSpeechRecognizer(locale: Locale(identifier: id)) else {
                print("  \(id): no recognizer")
                continue
            }
            print("  \(id): available=\(r.isAvailable) onDevice=\(r.supportsOnDeviceRecognition)")
        }
        print("\nThe app pins en-US deliberately. A locale that is available but not")
        print("on-device would leave scoring silently unavailable, because there is no")
        print("server fallback by design.")
    }
}
