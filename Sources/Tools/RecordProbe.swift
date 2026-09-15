import AVFoundation
import Foundation

// Records three seconds and reports what landed on disk.
//
// This is item 08's first step, and it needs a microphone grant. Run it before writing any
// recorder UI: if it fails, no amount of view work will help, and the failure message tells
// you whether the problem is the permission or the encoder.
//
//   ./probe.sh RecordProbe                    records 3s to a temp file, then deletes it
//   ./probe.sh RecordProbe ~/take.m4a          keeps the file, so you can play it back
//   ./probe.sh RecordProbe ~/take.m4a 6        records for 6 seconds
//
// Passes when the duration matches what was asked for within half a second, the file is at
// least 20 KB, and it opens in QuickTime.
//
// **Speak while it runs.** With nobody speaking the level stays at 0.00 and the no-input
// heuristic fires, which is correct behavior but tells you nothing about the encoder.

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

        // An explicit path keeps the recording, so it can be played back and handed to
        // TranscribeProbe. Without one the file is temporary.
        let args = Array(CommandLine.arguments.dropFirst())
        let keepPath = args.first
        let seconds = args.dropFirst().first.flatMap(Double.init) ?? 3.0
        let url = keepPath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("oe-record-probe-\(UUID().uuidString).m4a")
        let keep = keepPath != nil
        defer { if !keep { try? FileManager.default.removeItem(at: url) } }

        let recorder = AudioRecorderService()
        print("\nrecording \(Int(seconds)) seconds. SPEAK NOW -- read a sentence aloud.")
        do {
            try recorder.start(to: url)
        } catch let f as AppFailure {
            print("could not start: \(f.userMessage)")
            return
        }

        // Report the level as it goes, so a dead microphone is obvious immediately rather
        // than after the fact.
        var peak = 0.0
        let ticks = Int(seconds * 2)
        for tick in 0..<ticks {
            try? await Task.sleep(for: .milliseconds(500))
            peak = max(peak, recorder.level)
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

        print("  peak level: \(String(format: "%.2f", peak))")
        if peak < 0.05 {
            print("\n  The level never rose above the floor. Either nothing was said, or the")
            print("  microphone is muted in hardware. The encoder path is still proven by the")
            print("  frame count above; only the input is in question.")
        }

        let durationOK = abs(result.duration - seconds) < 0.5
        let sizeOK = size >= 20_000
        print("\nresult: duration \(durationOK ? "OK" : "OFF"), size \(sizeOK ? "OK" : "TOO SMALL")")
        if keep {
            print("\nkept at: \(result.url.path)")
            print("Play it, then score it against what you read:")
            print("  ./probe.sh TranscribeProbe \(result.url.path) \"the sentence you read\"")
        } else {
            print("\nTo keep the file and score it:")
            print("  ./probe.sh RecordProbe ~/take.m4a 6")
        }
    }
}
