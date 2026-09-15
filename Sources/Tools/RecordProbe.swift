import AVFoundation
import Foundation

// Records three seconds and reports what landed on disk.
//
// This is item 08's first step, and it needs a microphone grant. Run it before writing any
// recorder UI: if it fails, no amount of view work will help, and the failure message tells
// you whether the problem is the permission or the encoder.
//
//   ./probe.sh RecordProbe
//
// Passes when the duration is 3 seconds plus or minus 0.3, the file is at least 20 KB, and
// it opens in QuickTime.

@main
struct RecordProbe {
    @MainActor
    static func main() async throws {
        let permissions = PermissionService()
        permissions.refresh()
        print("microphone: \(permissions.microphone.rawValue)")

        if permissions.microphone != .granted {
            print("requesting the microphone. A dialog should appear.")
            let matrix = await permissions.requestForRecording()
            guard matrix.canRecord else {
                print("\nDENIED. Nothing further can be checked.")
                print("Grant it in System Settings, Privacy and Security, Microphone.")
                return
            }
        }

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("oe-record-probe-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = AudioRecorderService()
        print("\nrecording three seconds. Say something.")
        do {
            try recorder.start(to: url)
        } catch let f as AppFailure {
            print("could not start: \(f.userMessage)")
            return
        }

        // Report the level as it goes, so a dead microphone is obvious immediately rather
        // than after the fact.
        for tick in 0..<6 {
            try? await Task.sleep(for: .milliseconds(500))
            let bar = String(repeating: "#", count: Int(recorder.level * 30))
            print(String(format: "  %.1fs  level %.2f  %@", Double(tick + 1) * 0.5, recorder.level, bar))
        }

        let stopStart = Date()
        guard let result = await recorder.stop() else {
            print("\nstop produced no file at all.")
            return
        }

        let size = (try? result.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let stopElapsed = Date().timeIntervalSince(stopStart)
        print("\nstop() took \(String(format: "%.2f", stopElapsed))s")
        if stopElapsed > 4.0 {
            print("  That is the 5s deadline, so the finish delegate never fired.")
            print("  A command-line tool has no run loop, and AVAudioRecorder's delegate")
            print("  needs one -- the same trap as AVSpeechSynthesizer. The salvage path")
            print("  handled it, which is why there is still a readable file.")
        } else {
            print("  The finish delegate fired promptly.")
        }
        print("\nresult:")
        print("  duration: \(String(format: "%.2f", result.duration))s")
        print("  size: \(size) bytes")
        print("  finalized by the delegate: \(result.wasClean)")
        print("  no input detected: \(recorder.noInputDetected)")

        // Read it back the way the player and the recognizer will.
        if let file = try? AVAudioFile(forReading: result.url) {
            print("  readable: \(file.length) frames, \(Int(file.fileFormat.sampleRate)) Hz, "
                  + "\(file.fileFormat.channelCount) channel")
        } else {
            print("  NOT readable as audio -- the container was probably not finalized")
        }

        let durationOK = abs(result.duration - 3.0) < 0.5
        let sizeOK = size >= 20_000
        print("\nresult: duration \(durationOK ? "OK" : "OFF"), size \(sizeOK ? "OK" : "TOO SMALL")")
        print("Open it in QuickTime to confirm the AAC settings and the delegate await:")
        print("  \(result.url.path)")
        print("(this probe deletes it on exit, so copy it first if you want to)")
    }
}
