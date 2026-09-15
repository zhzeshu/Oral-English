import AVFoundation
import Foundation

// The whole practice loop, end to end, driven by spoken prompts.
//
//   ./probe.sh LoopProbe
//   ./probe.sh LoopProbe "The sentence to read." 8
//
// The prompts are SPOKEN and shown in a small floating window, because a terminal command
// cannot ask someone to speak on cue: this probe runs under `open`, so stdout is captured
// and printed only after it exits. Ava says what to do; the window holds the sentence on
// screen while it is read, because hearing a line once and reciting it from memory measures
// memory rather than pronunciation.
//
// This also answers the question the scorer depends on and cannot answer for itself:
// whether SFTranscriptionSegment.confidence is non-zero on this machine.

@main
struct LoopProbe {
    @MainActor
    static func main() {
        // Inside a real NSApplication, so the privacy prompts have somewhere to appear.
        ProbeApp.run { await body() }
    }

    @MainActor
    static func body() async {
        do { try await loop() } catch { print("failed: \(error)") }
    }

    @MainActor
    static func loop() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        let sentence = args.first ?? "The fog came in on little cat feet."
        let recordSeconds = args.dropFirst().first.flatMap(Double.init) ?? 7.0

        let provider = AppleVoiceProvider()
        let voices = await provider.availableVoices()
        guard let voice = VoiceRanking.best(voices) else {
            print("no English voice installed")
            return
        }
        print("reference voice: \(voice.name) [\(voice.tier.label)]")
        print("sentence: \"\(sentence)\"")
        print("\nListen to your speakers. The sentence is on screen in the probe window.\n")
        ProbeApp.prompt(sentence: sentence, status: "checking permissions…")

        let permissions = PermissionService()
        permissions.refresh()
        print("microphone: \(permissions.microphone.rawValue), "
              + "recognition: \(permissions.recognition.rawValue)")
        if permissions.microphone != .granted || permissions.recognition != .granted {
            print("requesting — two dialogs should appear")
            _ = await permissions.requestForRecording()
            permissions.refresh()
            print("after: microphone \(permissions.microphone.rawValue), "
                  + "recognition \(permissions.recognition.rawValue)")
        }
        guard permissions.matrix.canRecord else {
            print("\nmicrophone not available; cannot continue")
            print("bundle: \(Bundle.main.bundleIdentifier ?? "nil") at \(Bundle.main.bundlePath)")
            print("Grant it in System Settings, Privacy and Security, Microphone,")
            print("or run this probe in direct mode, which borrows the terminal's grant:")
            print("  ORAL_PROBE_DIRECT=1 ./probe.sh LoopProbe")
            return
        }
        let canScore = permissions.matrix.canScore

        func say(_ text: String) async {
            try? await provider.speak(text, voice: voice, rate: 0.45) { _, _ in }
        }

        // 1. Instruction, then the reference, then a clear go signal.
        ProbeApp.prompt(status: "listen first — do not read yet")
        await say("Listen to this sentence, then read it back after the tone.")
        try? await Task.sleep(for: .milliseconds(400))
        print("playing the reference…")
        ProbeApp.prompt(status: "playing the reference…")
        await say(sentence)
        try? await Task.sleep(for: .milliseconds(600))
        ProbeApp.prompt(status: "get ready — three, two, one")
        await say("Now read it. Beginning in three. Two. One.")

        // Let the tail of synthesis clear before arming, so it does not bleed into the take.
        try? await Task.sleep(for: PracticeController.postSynthesisSettle)

        // 2. Record.
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Desktop/oral-english-loop-take.m4a")
        try? FileManager.default.removeItem(at: url)

        let recorder = AudioRecorderService()
        do {
            try recorder.start(to: url)
        } catch let f as AppFailure {
            print("could not start recording: \(f.userMessage)")
            return
        }
        print("RECORDING for \(Int(recordSeconds))s — speak now")
        ProbeApp.prompt(status: "READ IT NOW")

        var peak = 0.0
        let ticks = Int(recordSeconds * 2)
        for tick in 0..<ticks {
            try? await Task.sleep(for: .milliseconds(500))
            peak = max(peak, recorder.level)
            let bar = String(repeating: "#", count: Int(recorder.level * 40))
            print(String(format: "  %.1fs  %.2f  %@", Double(tick + 1) * 0.5, recorder.level, bar))
            // The same bar on screen, so a dead microphone is visible while there is still
            // time to do something about it rather than in the report afterwards.
            let elapsed = Double(ticks - tick - 1) * 0.5
            ProbeApp.prompt(status: "recording — \(String(format: "%.0f", elapsed))s left   "
                            + String(repeating: "▁", count: max(1, Int(recorder.level * 30))))
        }

        guard let result = await recorder.stop() else {
            print("no file was produced")
            return
        }
        await say("Thank you.")

        let size = (try? result.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        print("\nrecorded: \(String(format: "%.2f", result.duration))s, \(size) bytes, "
              + "peak level \(String(format: "%.2f", peak)), clean: \(result.wasClean)")
        print("kept at: \(result.url.path)")

        if peak < 0.05 {
            ProbeApp.prompt(status: "nothing was captured — the level never left the floor")
            print("\nThe level never rose above the floor, so nothing was captured.")
            print("Either the prompt was not heard, or the microphone is muted in hardware.")
            return
        }

        // 3. Transcribe. Recording is still worth keeping when scoring is unavailable.
        guard canScore else {
            ProbeApp.prompt(status: "recorded, but recognition is not granted — no score")
            print("\nrecognition unavailable: \(permissions.matrix.scoringNote ?? "not granted")")
            print("The take is kept, so it can be scored later:")
            print("  ./probe.sh TranscribeProbe \(result.url.path) \"\(sentence)\"")
            try? await Task.sleep(for: .seconds(4))
            ProbeApp.dismissPrompt()
            return
        }
        print("\ntranscribing on this machine…")
        ProbeApp.prompt(status: "transcribing on this Mac…")
        let transcriber = TranscriberService()
        let transcript: Transcript
        do {
            transcript = try await transcriber.transcribe(fileURL: result.url)
        } catch let f as AppFailure {
            print("recognition failed: \(f.userMessage)  (key: \(f.key))")
            return
        }
        print("heard: \"\(transcript.text)\"")

        // 4. The confidence question.
        let confidences = transcript.words.map(\.confidence)
        let distinct = Set(confidences).count
        print("\nper-word confidence: \(confidences.count) words, \(distinct) distinct values, "
              + "mean \(String(format: "%.3f", transcript.meanConfidence))")
        for w in transcript.words.prefix(12) {
            print(String(format: "  %-14s conf %.3f  at %.2fs", (w.text as NSString).utf8String!,
                         w.confidence, w.startTime))
        }
        if !confidences.isEmpty && confidences.allSatisfy({ $0 == 0 }) {
            print("\n  ALL ZERO — the hard-to-hear rule cannot use this signal.")
            print("  Switch to the documented fallback: recorder metering plus missed-word ratio.")
        } else if distinct > 1 {
            print("\n  Non-zero and varying — the hard-to-hear rule works as designed.")
        } else {
            print("\n  Non-zero but constant — treat with suspicion, try another take.")
        }

        // 5. Score.
        let report = Scorer.score(reference: sentence, transcript: transcript)
        print("\nscore: \(Int((report.accuracy * 100).rounded())) percent, verdict \(report.verdict.rawValue)")
        print("  \(report.matchCount) matched, \(report.partialCount) close, "
              + "\(report.substitutionCount) wrong, \(report.missedCount) missed, \(report.extraCount) extra")
        if !report.problemWords.isEmpty {
            print("  words to work on: \(report.problemWords.joined(separator: ", "))")
        }
        ProbeApp.prompt(status: "\(Int((report.accuracy * 100).rounded()))% — \(report.verdict.rawValue)"
                        + "   (heard: \(transcript.text))")

        print("\n  word by word:")
        for w in report.words {
            let mark: String
            switch w.status {
            case .match: mark = "ok     "
            case .partial: mark = "close  "
            case .substituted: mark = "wrong  "
            case .missed: mark = "missed "
            case .extra: mark = "extra  "
            }
            print("    \(mark) \(w.display)\(w.heard.map { $0 == w.normalized ? "" : "  (heard \"\($0)\")" } ?? "")")
        }

        // ProbeApp terminates the process the moment this returns, which would take the
        // window with it before the score could be read.
        try? await Task.sleep(for: .seconds(6))
        ProbeApp.dismissPrompt()
    }
}
