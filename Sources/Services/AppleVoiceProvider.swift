import AVFoundation
import Foundation

/// The reference voice over `AVSpeechSynthesizer`.
@MainActor
public final class AppleVoiceProvider: ReferenceVoice {

    /// Must be a stored property. A locally-scoped synthesizer deallocates and speech stops
    /// instantly, which presents as "it plays nothing" with no error.
    private let synthesizer = AVSpeechSynthesizer()
    private var activeDelegate: SynthDelegate?

    public init() {}

    /// Nothing leaves the machine. Asserted by test.
    public var dataLeavesDevice: Bool { false }

    public func availableVoices() async -> [VoiceOption] {
        AVSpeechSynthesisVoice.speechVoices().compactMap { v in
            guard v.language.hasPrefix("en") else { return nil }
            return VoiceOption(
                id: v.identifier,
                name: v.name,
                language: v.language,
                tier: Self.tier(for: v.quality)
            )
        }
    }

    public static func tier(for quality: AVSpeechSynthesisVoiceQuality) -> VoiceTier {
        switch quality {
        case .premium: return .premium
        case .enhanced: return .enhanced
        case .default: return .compact
        @unknown default: return .compact
        }
    }

    // MARK: - Speaking

    public func speak(
        _ text: String,
        voice: VoiceOption?,
        rate: Double,
        onWord: @escaping @Sendable (Int, Int) -> Void
    ) async throws {
        stop()

        let utterance = makeUtterance(text, voice: voice, rate: rate)
        let shim = SynthDelegate(
            operation: "playing the reference",
            // The deadline is silence *between* callbacks, not total speech length, so a
            // long sentence is not cut off.
            timeout: Deadlines.synthesisCallback + .seconds(text.count / 8),
            onWord: onWord
        )
        activeDelegate = shim
        synthesizer.delegate = shim
        synthesizer.speak(utterance)

        defer {
            synthesizer.delegate = nil
            activeDelegate = nil
        }
        _ = try await shim.value()
    }

    public func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        activeDelegate?.complete(())
        activeDelegate = nil
    }

    private func makeUtterance(_ text: String, voice: VoiceOption?, rate: Double) -> AVSpeechUtterance {
        let u = AVSpeechUtterance(string: text)
        if let id = voice?.id, let resolved = AVSpeechSynthesisVoice(identifier: id) {
            u.voice = resolved
        }
        u.rate = Float(rate)
        u.preUtteranceDelay = 0
        return u
    }

    // MARK: - Baking

    /// Writes the audio to a file.
    ///
    /// Needed for A/B overlay, which cannot be time-aligned against live synthesis, and for
    /// exports that play without the app. The buffer callback yields 22050 Hz mono
    /// non-interleaved float — note that recordings are 44100 Hz, so anything feeding both
    /// into one pipeline has to convert.
    public func bake(_ text: String, voice: VoiceOption?, rate: Double, to url: URL) async throws {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)

        let utterance = makeUtterance(text, voice: voice, rate: rate)
        let writer = BakeWriter(url: url)
        let shim = OneShot<Void>(operation: "preparing the reference audio", timeout: .seconds(30))

        synthesizer.write(utterance) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 {
                do {
                    try writer.finish()
                    shim.complete(())
                } catch {
                    shim.fail(error)
                }
                return
            }
            do {
                try writer.append(pcm)
            } catch {
                shim.fail(error)
            }
        }

        try await shim.value()
    }
}

/// Collects synthesis buffers into a file. The first buffer defines the format.
private final class BakeWriter: @unchecked Sendable {
    private let url: URL
    private var file: AVAudioFile?

    init(url: URL) { self.url = url }

    func append(_ buffer: AVAudioPCMBuffer) throws {
        if file == nil {
            file = try AVAudioFile(
                forWriting: url,
                settings: buffer.format.settings,
                commonFormat: buffer.format.commonFormat,
                interleaved: buffer.format.isInterleaved
            )
        }
        try file?.write(from: buffer)
    }

    func finish() throws {
        file = nil
    }
}

/// One shim per utterance.
private final class SynthDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let shot: OneShot<Void>
    private let onWord: @Sendable (Int, Int) -> Void

    init(operation: String, timeout: Duration, onWord: @escaping @Sendable (Int, Int) -> Void) {
        self.shot = OneShot(operation: operation, timeout: timeout)
        self.onWord = onWord
        super.init()
    }

    func value() async throws -> Void { try await shot.value() }
    func complete(_ v: Void) { shot.complete(()) }

    /// Converts the `NSRange` to plain integers *inside* the callback, so nothing
    /// non-Sendable crosses an isolation boundary. The offsets are UTF-16.
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        onWord(characterRange.location, characterRange.length)
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        shot.complete(())
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        shot.complete(())
    }
}
