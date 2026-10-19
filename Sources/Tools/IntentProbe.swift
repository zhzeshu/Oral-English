import AVFoundation
import Foundation

// Drives AppModel's record intent against a scratch library, with no UI.
//
//   ORAL_PROBE_DIRECT=1 ./probe.sh IntentProbe [seconds]
//
// Every other probe stops at the service boundary: AudioRecorderService records, the store
// stores. This one runs the sequence a button press actually runs -- permissions, staging,
// start, stop, acceptance, adopt, append, score -- because a bug can live in the ordering
// of those steps while every part works on its own. "Recording is not working" in the app
// while RecordProbe succeeds is exactly that shape.

@main
struct IntentProbe {
    @MainActor
    static func main() async throws {
        setvbuf(stdout, nil, _IONBF, 0)

        let seconds = CommandLine.arguments.dropFirst().first.flatMap(Double.init) ?? 4.0

        // A scratch library, so the probe cannot disturb real practice data and cannot
        // collide with the running app over the single-instance lock.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("oe-intent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = Settings(defaults: UserDefaults(suiteName: "oe-intent-probe")!)
        settings.libraryPathOverride = root.path
        print("library: \(root.path)")

        let model = AppModel(settings: settings)
        await model.bootstrap()
        if model.isAnotherInstanceRunning {
            print("FAIL: the single-instance lock refused a scratch library")
            return
        }
        report("bootstrap", model)

        // Phase 1 needs no permission at all, so it always runs.
        try await highlightPhase(model)

        let sentence = "The fog came in on little cat feet."
        await model.createPassage(title: "Intent probe", theme: nil, text: sentence)
        report("createPassage", model)
        guard let loaded = model.loaded, let first = loaded.passage.sentences.first else {
            print("FAIL: no passage was created")
            return
        }
        let ref = TargetRef.sentence(first.id)
        model.selectedTarget = ref

        print("\npermissions: mic \(model.permissions.microphone.rawValue), "
              + "recognition \(model.permissions.recognition.rawValue), "
              + "canRecord \(model.permissions.matrix.canRecord)")

        // In direct mode the TERMINAL is the responsible process for privacy, and it has no
        // NSSpeechRecognitionUsageDescription -- so the moment the record intent requests
        // recognition, TCC kills the process with SIGABRT and no explanation. Caught here
        // rather than suffered, because an abort looks like a defect in the code under test.
        // Keyed on direct mode itself, not on Bundle.main: the probe binary lives inside a
        // real .app, so NSBundle.main finds the usage string and reports all clear while
        // TCC -- which consults the responsible process, the terminal -- does not. Checking
        // the bundle looked right and did not fire.
        if model.permissions.recognition.needsAsking,
           ProcessInfo.processInfo.environment["ORAL_PROBE_DIRECT"] == "1" {
            print("\nSTOP: recognition has not been granted, and this process has no speech")
            print("usage string, so requesting it would abort rather than prompt.")
            print("Run without ORAL_PROBE_DIRECT so the probe bundle is responsible:")
            print("  ./probe.sh IntentProbe 5")
            return
        }

        print("\nstartRecording…")
        await model.startRecording(ref)
        report("startRecording", model)
        print("  practice.audio:     \(model.practice.audio)")
        print("  recorder.isRecording: \(model.recorder.isRecording)")
        guard model.isRecording(ref) else {
            print("\nFAIL: the model does not consider itself recording. Nothing was armed.")
            return
        }

        // ORAL_SPEAK=1 plays the sentence through the speakers while the take runs, so the
        // microphone captures real words. Not a substitute for a human reading -- the point
        // is to exercise recognition and scoring with speech rather than room noise, which
        // is otherwise the difference between "the pipeline is broken" and "nobody spoke".
        let speakIt = ProcessInfo.processInfo.environment["ORAL_SPEAK"] == "1"
        if speakIt {
            let provider = AppleVoiceProvider()
            let voices = await provider.availableVoices()
            if let voice = VoiceRanking.best(voices) {
                print("\nspeaking the sentence into the room with \(voice.name)")
                Task { try? await provider.speak(sentence, voice: voice, rate: 0.4) { _, _ in } }
            }
        }

        print("\nrecording \(Int(seconds))s — make some noise")
        for tick in 0..<Int(seconds * 2) {
            try? await Task.sleep(for: .milliseconds(500))
            let bar = String(repeating: "#", count: Int(model.recorderLevel * 30))
            print(String(format: "  %.1fs  %.2f  %@", Double(tick + 1) * 0.5, model.recorderLevel, bar))
        }
        let peak = model.recorder.peakLevel

        print("\nstopRecording…")
        await model.stopRecording()
        report("stopRecording", model)
        print("  practice.audio:     \(model.practice.audio)")
        print("  peak level:         \(String(format: "%.2f", peak))")

        // The question the whole probe exists to answer.
        let takes = model.loaded?.takes ?? []
        print("\ntakes in the library: \(takes.count)")
        for take in takes {
            let url = await model.store.resolve(relativePath: take.audioPath, in: model.selectedFolder!)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            print("  \(take.audioPath)  \(size) bytes  \(String(format: "%.2f", take.durationSeconds))s")
            print("  reference: \"\(take.referenceText)\"")
            if let score = take.score {
                print("  score: \(Int((score.accuracy * 100).rounded()))% \(score.verdict.rawValue)")
                print("  heard: \"\(score.transcript)\"  meanConfidence \(String(format: "%.3f", score.meanConfidence))")
            } else {
                print("  NOT SCORED")
            }
        }

        print("\nrow summary for the target:")
        if let row = model.rowSummaries[ref] {
            print("  takeCount \(row.takeCount), bestAccuracy "
                  + "\(row.bestAccuracy.map { String(format: "%.2f", $0) } ?? "nil"), "
                  + "verdict \(row.verdict.map(String.init(describing:)) ?? "nil")")
        } else {
            print("  MISSING — the row would show nothing")
        }

        print("\nresult: \(takes.isEmpty ? "FAIL — no take was created" : "a take exists on disk")")
    }

    /// Does the highlight walk the whole paragraph, or stop inside the first sentence?
    ///
    /// The reported bug: "when read in paragraph and whole, the highlight only run on the
    /// first sentence". Synthesis speaks one utterance per sentence and reports word offsets
    /// from zero each time, so a paragraph row that applied them raw kept re-highlighting
    /// its opening words. This samples the range the row would actually draw and reports
    /// which sentence each highlighted word fell in.
    @MainActor
    private static func highlightPhase(_ model: AppModel) async throws {
        let sentences = [
            "The fog comes on little cat feet.",
            "It sits looking over harbor and city.",
            "Then moves on.",
        ]
        await model.createPassage(title: "Highlight probe", theme: nil,
                                  text: sentences.joined(separator: " "))
        guard let loaded = model.loaded, let paragraph = loaded.passage.paragraphs.first else {
            print("FAIL: no paragraph to test highlighting against")
            return
        }
        let ref = TargetRef.paragraph(paragraph.id)
        let text = loaded.passage.text(for: ref) ?? ""
        print("\nhighlight check over a \(loaded.passage.sentences.count)-sentence paragraph")

        let starts = SpokenRange.sentenceStarts(in: text, sentences: sentences)
        print("  sentence starts: \(starts)")

        let speaking = Task { await model.playReference(ref) }
        var hitsPerSentence = [Int](repeating: 0, count: sentences.count)
        var samples: [String] = []
        while !speaking.isCancelled, model.practice.speakingTarget != nil || samples.isEmpty {
            try? await Task.sleep(for: .milliseconds(60))
            guard let r = model.spokenRange(for: ref) else {
                if model.practice.speakingTarget == nil && !samples.isEmpty { break }
                continue
            }
            guard let word = SpokenRange.substring(in: text, utf16Location: r.location,
                                                   utf16Length: r.length) else { continue }
            if samples.last != word { samples.append(word) }
            // Which sentence does this offset fall inside?
            let index = starts.lastIndex(where: { $0 <= r.location }) ?? 0
            hitsPerSentence[index] += 1
        }
        await speaking.value

        print("  highlighted words, in order:")
        print("    \(samples.joined(separator: " · "))")
        for (i, count) in hitsPerSentence.enumerated() {
            let mark = count > 0 ? "ok" : "NEVER HIGHLIGHTED"
            print("    sentence \(i + 1): \(count) samples  \(mark)")
        }
        let reached = hitsPerSentence.filter { $0 > 0 }.count
        print("  result: the highlight reached \(reached) of \(sentences.count) sentences "
              + (reached == sentences.count ? "— PASS" : "— FAIL"))
    }

    /// Any step that sets `errorMessage` has reported a user-visible failure, and the probe
    /// should surface it at the point it happened rather than let the next step mask it.
    @MainActor
    private static func report(_ step: String, _ model: AppModel) {
        if let message = model.errorMessage {
            print("  [\(step)] errorMessage: \(message)")
            model.errorMessage = nil
        }
    }
}
