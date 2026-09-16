import Foundation
import Speech

// Answers one question: is an on-device speech model actually INSTALLED on this machine?
//
// Written because legacy SFSpeechRecognizer returns an empty final result instantly for
// audio known to contain clear speech, while reporting `isAvailable=true` and
// `supportsOnDeviceRecognition=true`. Those two legacy flags report *capability*, not
// installation. On macOS 26 the on-device assets are managed by `AssetInventory`, so this
// probe reads the real installation state and the modern API's availability.
//
//   ./probe.sh AssetProbe

@main
struct AssetProbe {
    @MainActor
    static func main() async {
        print("OS: \(ProcessInfo.processInfo.operatingSystemVersionString)")

        let enUS = Locale(identifier: "en-US")

        print("\n-- legacy SFSpeechRecognizer (what the app uses today) --")
        if let r = SFSpeechRecognizer(locale: enUS) {
            print("  isAvailable:                 \(r.isAvailable)")
            print("  supportsOnDeviceRecognition: \(r.supportsOnDeviceRecognition)")
        } else {
            print("  no recognizer for en-US")
        }
        print("  authorizationStatus:         \(SFSpeechRecognizer.authorizationStatus().rawValue)")

        guard #available(macOS 26.0, *) else {
            print("\nmacOS 26 Speech API unavailable at runtime; nothing more to check.")
            return
        }

        print("\n-- modern Speech API --")
        print("  SpeechTranscriber.isAvailable: \(SpeechTranscriber.isAvailable)")

        let supported = await SpeechTranscriber.supportedLocales
        let installed = await SpeechTranscriber.installedLocales
        print("  supportedLocales: \(supported.count)")
        print("  installedLocales: \(installed.count)")

        func has(_ list: [Locale]) -> Bool {
            list.contains { $0.identifier(.bcp47).lowercased().hasPrefix("en-us") }
        }
        print("  en-US supported: \(has(supported))")
        print("  en-US INSTALLED: \(has(installed))")
        if !installed.isEmpty {
            print("  installed: \(installed.map { $0.identifier(.bcp47) }.joined(separator: ", "))")
        }

        let transcriber = SpeechTranscriber(
            locale: enUS,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.transcriptionConfidence])
        let status = await AssetInventory.status(forModules: [transcriber])
        print("\n  AssetInventory.status for en-US: \(String(describing: status))")

        switch status {
        case .installed:
            print("  => The model is installed. The empty transcript is NOT a missing asset.")
        case .supported:
            print("  => Reported `supported`, not `installed`, for THIS module")
            print("     configuration. Note this can disagree with installedLocales above,")
            print("     because status is per-module: base en-US assets can be present")
            print("     while the assets for the requested attribute options are not.")
            print("     Suggestive of a missing-asset cause for the empty legacy")
            print("     transcript, but NOT conclusive on its own -- the decisive test is")
            print("     transcribing the same file through SpeechTranscriber and seeing")
            print("     whether words come back.")
            print("     Install with AssetInventory.assetInstallationRequest(supporting:).")
        case .downloading:
            print("  => Currently downloading. Re-run once it finishes.")
        case .unsupported:
            print("  => Unsupported on this machine.")
        @unknown default:
            print("  => Unknown status.")
        }

        print("\n  attributeOptions includes .transcriptionConfidence, so the modern API")
        print("  reports confidence explicitly -- relevant to item 03's hard-to-hear rule.")
    }
}
