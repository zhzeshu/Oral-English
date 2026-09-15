import AVFoundation
import Foundation

// Proves the synthesizer behaves as expected before any app code depends on it.
//
// Silent by design: it uses the write-to-file path rather than speaking aloud, and word
// callbacks fire during that path too, so both claims can be checked without making noise.
//
// A command-line tool has no run loop, and without one AVSpeechSynthesizer produces zero
// frames and zero callbacks with no error at all. Confirmed by experiment. So this pumps
// the run loop explicitly. Do not conclude the API is broken.
//
// Note the entry point is SYNCHRONOUS. `RunLoop.current` and `run(mode:before:)` are both
// marked unavailable from an async context, so a probe that has to pump the run loop cannot
// be `async`. Any later probe with the same need has the same constraint.

@main
struct VoiceProbe {
    @MainActor
    static func main() throws {
        // Built inline rather than through the provider, because the provider's accessor is
        // async and this entry point cannot be.
        let voices: [VoiceOption] = AVSpeechSynthesisVoice.speechVoices().compactMap { v in
            guard v.language.hasPrefix("en") else { return nil }
            return VoiceOption(
                id: v.identifier, name: v.name, language: v.language,
                tier: AppleVoiceProvider.tier(for: v.quality))
        }

        print("installed English voices: \(voices.count)")
        var byTier: [VoiceTier: Int] = [:]
        for v in voices { byTier[v.tier, default: 0] += 1 }
        for tier in VoiceTier.allCases.reversed() {
            print("  \(tier.label): \(byTier[tier] ?? 0)")
        }

        let good = voices.filter { $0.tier.isGoodEnough }
        if good.isEmpty {
            print("\nNO voice above the lowest tier is installed.")
            print("That is the entire reason built-in speech sounds robotic.")
            print("\n\(VoiceCatalog.downloadInstructions)")
        } else {
            print("\nbetter voices installed:")
            for v in VoiceRanking.ranked(good) {
                print("  \(v.name)  [\(v.tier.label)]  \(v.language)  \(v.id)")
            }
        }

        guard let selected = VoiceRanking.best(voices) else {
            print("\nno English voice at all; nothing further to check")
            return
        }
        print("\nselected by ranking: \(selected.name) [\(selected.tier.label)] \(selected.id)")
        print("  (never the system default, which is the compact voice)")

        // Word callbacks, counted during the silent write path.
        let sentence = "The fog came in on little cat feet."
        let expectedWords = sentence.split(separator: " ").count
        let counter = WordCounter()

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("oe-voice-probe-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }

        let synth = AVSpeechSynthesizer()
        let delegate = CountingDelegate(counter: counter)
        synth.delegate = delegate

        let utterance = AVSpeechUtterance(string: sentence)
        utterance.voice = AVSpeechSynthesisVoice(identifier: selected.id)

        var frames: AVAudioFrameCount = 0
        var format = "none"
        var done = false
        synth.write(utterance) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 { done = true; return }
            frames += pcm.frameLength
            format = "\(Int(pcm.format.sampleRate)) Hz, \(pcm.format.channelCount) channel, "
                + "\(pcm.format.isInterleaved ? "interleaved" : "non-interleaved")"
        }

        let deadline = Date().addingTimeInterval(20)
        while !done && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        print("\nsynthesis:")
        print("  frames: \(frames)")
        print("  format: \(format)")
        // At least one per word, not exactly one: the synthesizer emitted 9 ranges for an
        // 8-word sentence, apparently giving the trailing period its own range. So the app
        // must consume ranges as they arrive rather than assuming a 1:1 mapping.
        print("  word callbacks: \(counter.count) (at least \(expectedWords) expected)")
        print("  first four words seen: \(counter.words.prefix(4))")

        print("\nresult: frames \(frames > 0 ? "OK" : "FAILED"), "
              + "callbacks \(counter.count >= expectedWords ? "OK" : "TOO FEW")")

        if counter.count == 0 {
            print("  No range callbacks is a SUPPORTED case, not a bug: the app degrades to")
            print("  highlighting the whole sentence rather than appearing broken.")
        }

        print("\nnote: recordings are 44100 Hz, synthesis is 22050 Hz. Anything feeding both")
        print("into one buffer pipeline has to convert -- see item 10.")
        print("dataLeavesDevice: \(AppleVoiceProvider().dataLeavesDevice)")
    }
}

final class WordCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []
    func add(_ word: String) { lock.withLock { seen.append(word) } }
    var count: Int { lock.withLock { seen.count } }
    var words: [String] { lock.withLock { seen } }
}

final class CountingDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    let counter: WordCounter
    init(counter: WordCounter) { self.counter = counter; super.init() }

    nonisolated func speechSynthesizer(
        _ s: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        // UTF-16 offsets, converted through the pure helper so the probe exercises the same
        // code path the app uses.
        if let word = SpokenRange.substring(
            in: utterance.speechString,
            utf16Location: characterRange.location,
            utf16Length: characterRange.length
        ) {
            counter.add(word)
        }
    }
}
