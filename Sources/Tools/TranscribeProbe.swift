import AVFoundation
import Foundation
import Speech

// Transcribes an audio file on this machine and prints the result with per-segment
// confidence and timing.
//
//   ./probe.sh TranscribeProbe /path/to/take.m4a
//
// This is item 10's first step. It answers the question item 03 depends on and cannot
// answer for itself: **is per-segment confidence actually non-zero on this machine?**
// SFTranscriptionSegment.confidence is commonly reported as 0.0 for on-device results. If
// it is uniformly zero here, the hard-to-hear rule rests on a constant and every take would
// trip it, so the app would never show a score again. Item 03 specifies the fallback.
//
// Save the output. Item 11 calibrates against these transcripts, and capturing them now
// saves re-recording later.

@main
struct TranscribeProbe {
    @MainActor
    static func main() async throws {
        guard let path = CommandLine.arguments.dropFirst().first else {
            print("Usage: ./probe.sh TranscribeProbe <audio-file> [reference text]")
            return
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("no such file: \(path)")
            return
        }

        let permissions = PermissionService()
        permissions.refresh()
        print("speech recognition: \(permissions.recognition.rawValue)")
        print("offline en-US model: \(permissions.offlineModelAvailable ? "available" : "NOT available")")

        if permissions.recognition != .granted {
            print("\nrequesting recognition. A dialog should appear.")
            _ = await permissions.requestForRecording()
            permissions.refresh()
            guard permissions.recognition == .granted else {
                print("DENIED. Nothing further can be checked.")
                return
            }
        }

        if let file = try? AVAudioFile(forReading: url) {
            let seconds = Double(file.length) / file.fileFormat.sampleRate
            print("\naudio: \(String(format: "%.2f", seconds))s, "
                  + "\(Int(file.fileFormat.sampleRate)) Hz, \(file.fileFormat.channelCount) channel")
            if seconds > ChunkPlan.singleRequestLimit {
                let plan = ChunkPlan.plan(totalDuration: seconds)
                print("  will be chunked into \(plan.count): "
                      + plan.map { String(format: "%.0f-%.0fs", $0.start, $0.end) }.joined(separator: ", "))
            }
        }

        let transcriber = TranscriberService()
        let start = Date()
        let transcript: Transcript
        do {
            transcript = try await transcriber.transcribe(fileURL: url)
        } catch let f as AppFailure {
            print("\nfailed: \(f.userMessage)")
            print("(key: \(f.key))")
            return
        }
        let elapsed = Date().timeIntervalSince(start)

        print("\ntranscript (\(String(format: "%.2f", elapsed))s):")
        print("  \"\(transcript.text)\"")

        print("\nper-word confidence and timing:")
        for w in transcript.words.prefix(20) {
            print(String(format: "  %-16s conf %.3f  at %.2fs for %.2fs",
                         (w.text as NSString).utf8String!, w.confidence, w.startTime, w.duration))
        }

        // The question item 03 depends on.
        let confidences = transcript.words.map(\.confidence)
        let allZero = !confidences.isEmpty && confidences.allSatisfy { $0 == 0 }
        let varying = Set(confidences).count > 1
        print("\nconfidence: mean \(String(format: "%.3f", transcript.meanConfidence)), "
              + "distinct values \(Set(confidences).count)")
        if allZero {
            print("  ALL ZERO. Item 03's hard-to-hear rule cannot use this signal.")
            print("  Switch to the fallback: recorder metering plus the missed-word ratio.")
        } else if varying {
            print("  Non-zero and varying. The hard-to-hear rule can use it as designed.")
        } else {
            print("  Non-zero but constant. Treat with suspicion; check another take.")
        }

        // Timings must increase, which is what the chunk splice exists to guarantee.
        let starts = transcript.words.map(\.startTime)
        let monotonic = zip(starts, starts.dropFirst()).allSatisfy { $0 <= $1 }
        print("timings monotonic across the whole transcript: \(monotonic ? "yes" : "NO -- the chunk offset is wrong")")

        // Score it, if a reference was given.
        if let reference = CommandLine.arguments.dropFirst(2).first {
            let report = Scorer.score(reference: reference, transcript: transcript)
            print("\nscored against \"\(reference)\":")
            print("  accuracy \(Int((report.accuracy * 100).rounded())) percent, verdict \(report.verdict.rawValue)")
            print("  \(report.matchCount) matched, \(report.partialCount) close, "
                  + "\(report.substitutionCount) wrong, \(report.missedCount) missed, \(report.extraCount) extra")
            if !report.problemWords.isEmpty {
                print("  words to work on: \(report.problemWords.joined(separator: ", "))")
            }
        }
    }
}
