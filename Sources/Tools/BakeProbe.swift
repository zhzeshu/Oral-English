import AVFoundation
import Foundation

// Checks that baking reference audio produces a real, readable file.
//
// Async entry point, which works here because the continuation in OneShot is driven by the
// Swift concurrency runtime rather than by a run loop this code has to pump itself.

@main
struct BakeProbe {
    @MainActor
    static func main() async throws {
        let provider = AppleVoiceProvider()
        let voices = await provider.availableVoices()
        guard let selected = VoiceRanking.best(voices) else {
            print("no English voice installed")
            return
        }
        print("voice: \(selected.name) [\(selected.tier.label)]")

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("oe-bake-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }

        let sentence = "The fog came in on little cat feet."
        let start = Date()
        try await provider.bake(sentence, voice: selected, rate: 0.45, to: url)
        let elapsed = Date().timeIntervalSince(start)

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        print("baked in \(String(format: "%.2f", elapsed))s, \(size) bytes")

        // Read it back the way the player will.
        let file = try AVAudioFile(forReading: url)
        let seconds = Double(file.length) / file.fileFormat.sampleRate
        print("readable: \(file.length) frames, \(Int(file.fileFormat.sampleRate)) Hz, "
              + "\(file.fileFormat.channelCount) channel, \(String(format: "%.2f", seconds))s")

        let player = try AVAudioPlayer(contentsOf: url)
        print("AVAudioPlayer accepts it: duration \(String(format: "%.2f", player.duration))s")

        print("\nresult: \(size > 1000 && file.length > 0 ? "OK" : "FAILED")")
    }
}
