import AVFoundation
import Foundation

// Bakes the same sentence with the best installed voice and with the old compact voice, to
// two opaquely-named files, so the difference can be judged by ear without knowing which is
// which. This is item 07's acceptance test.

@main
struct CompareProbe {
    @MainActor
    static func main() async throws {
        let sentence = CommandLine.arguments.dropFirst().first
            ?? "The fog came in on little cat feet. It sat looking over harbor and city."

        let provider = AppleVoiceProvider()
        let voices = await provider.availableVoices()
        guard let best = VoiceRanking.best(voices) else {
            print("no English voice installed")
            return
        }
        guard let compact = voices.first(where: { $0.id == "com.apple.voice.compact.en-US.Samantha" })
            ?? voices.first(where: { $0.tier == .compact && $0.family == .system }) else {
            print("no compact voice to compare against")
            return
        }

        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Desktop/oral-english-voice-comparison", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Opaque names, so the comparison is blind. The key is written separately.
        let order = Bool.random()
        let fileA = dir.appendingPathComponent("sample-A.caf")
        let fileB = dir.appendingPathComponent("sample-B.caf")
        let (voiceA, voiceB) = order ? (best, compact) : (compact, best)

        try await provider.bake(sentence, voice: voiceA, rate: 0.45, to: fileA)
        try await provider.bake(sentence, voice: voiceB, rate: 0.45, to: fileB)

        let key = dir.appendingPathComponent("ANSWER-do-not-open-first.txt")
        try """
        sample-A.caf  =  \(voiceA.name)  [\(voiceA.tier.label)]  \(voiceA.id)
        sample-B.caf  =  \(voiceB.name)  [\(voiceB.tier.label)]  \(voiceB.id)

        Sentence: \(sentence)
        """.write(to: key, atomically: true, encoding: .utf8)

        print("sentence: \"\(sentence)\"")
        print("\nbaked two samples to:")
        print("  \(dir.path)")
        print("\n  sample-A.caf")
        print("  sample-B.caf")
        print("  ANSWER-do-not-open-first.txt")
        print("\nPlay both, decide which sounds more like a native speaker, then open the")
        print("answer file. The comparison is blind on purpose: judging a voice against a")
        print("memory of another voice is not a test that can fail.")

        for (label, url) in [("A", fileA), ("B", fileB)] {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let file = try AVAudioFile(forReading: url)
            print("\n  sample-\(label): \(size) bytes, \(Int(file.fileFormat.sampleRate)) Hz, "
                  + String(format: "%.2fs", Double(file.length) / file.fileFormat.sampleRate))
        }
    }
}
