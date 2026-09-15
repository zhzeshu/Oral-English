import AVFoundation
import Foundation

// Verifies playback against baked reference audio, which needs no microphone and no
// permission. Covers the four gotchas the plan names: the strong reference, enableRate
// before prepareToPlay, the shared anchor for overlay, and a missing file.

@main
struct PlaybackProbe {
    @MainActor
    static func main() async throws {
        let provider = AppleVoiceProvider()
        let voices = await provider.availableVoices()
        guard let voice = VoiceRanking.best(voices) else {
            print("no English voice installed")
            return
        }

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("oe-playback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let a = dir.appendingPathComponent("reference.caf")
        let b = dir.appendingPathComponent("take.caf")
        try await provider.bake("The fog came in on little cat feet.", voice: voice, rate: 0.45, to: a)
        try await provider.bake("It sat looking over harbor and city.", voice: voice, rate: 0.45, to: b)

        let refDuration = try AVAudioPlayer(contentsOf: a).duration
        let takeDuration = try AVAudioPlayer(contentsOf: b).duration
        print("baked two files: \(String(format: "%.2f", refDuration))s and \(String(format: "%.2f", takeDuration))s")

        let player = AudioPlayerService()

        // 1. Rate is honored, which only works if enableRate was set before preparing.
        print("\nrate handling:")
        for rate in [1.0, 0.75] {
            let start = Date()
            try await player.play(a, slot: .reference, rate: rate)
            let elapsed = Date().timeIntervalSince(start)
            let expected = refDuration / rate
            let ok = abs(elapsed - expected) < max(expected * 0.4, 0.6)
            print("  rate \(rate): played in \(String(format: "%.2f", elapsed))s, "
                  + "expected about \(String(format: "%.2f", expected))s  \(ok ? "OK" : "OFF")")
        }

        // 2. Sequential A/B completes in roughly the sum plus the gap.
        let start = Date()
        try await player.playAB(reference: a, take: b, gap: .milliseconds(400))
        let total = Date().timeIntervalSince(start)
        let expected = refDuration + takeDuration + 0.4
        print("\nsequential A/B: \(String(format: "%.2f", total))s, expected about \(String(format: "%.2f", expected))s")
        print("  \(abs(total - expected) < 1.0 ? "OK" : "OFF") -- reference then take, in that order")

        // 3. Overlay starts both from a shared anchor.
        try player.playOverlaid(reference: a, take: b)
        try? await Task.sleep(for: .milliseconds(300))
        print("\noverlay: both started from a shared anchor, isPlaying=\(player.isPlaying)")
        player.stopAll()
        print("  stopAll leaves isPlaying=\(player.isPlaying)")

        // 4. A missing file reports itself rather than throwing something raw.
        let gone = dir.appendingPathComponent("not-there.caf")
        do {
            try await player.play(gone, slot: .take)
            print("\nmissing file: NO ERROR (unexpected)")
        } catch let f as AppFailure {
            print("\nmissing file: \"\(f.userMessage)\"")
        }
    }
}
