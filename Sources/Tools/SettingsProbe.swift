import AVFoundation
import Foundation

@main
struct SettingsProbe {
    @MainActor
    static func main() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("oe-settings-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }

        print("passed in:")
        for (k, v) in AudioRecorderService.settings.sorted(by: { $0.key < $1.key }) {
            print("  \(k) = \(v)  (\(type(of: v)))")
        }

        let recorder = try AVAudioRecorder(url: url, settings: AudioRecorderService.settings)
        print("\nreported back by the recorder:")
        for (k, v) in recorder.settings.sorted(by: { $0.key < $1.key }) {
            print("  \(k) = \(v)  (\(type(of: v)))")
        }
        print("\nsample rate as Double: \(recorder.settings[AVSampleRateKey] as? Double as Any)")
        print("sample rate as NSNumber: \(recorder.settings[AVSampleRateKey] as? NSNumber as Any)")
        print("format as Int: \(recorder.settings[AVFormatIDKey] as? Int as Any)")
    }
}
