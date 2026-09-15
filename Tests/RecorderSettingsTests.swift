import AVFoundation
import Foundation
import Testing

/// Guards the recorder's encoder settings.
///
/// These would otherwise be checked only by a probe, and every failure mode here is a quiet
/// one: linear PCM with an `.m4a` extension yields an unplayable file, and a sample rate
/// passed as `Int` rather than `Double` is **silently ignored**. That last one is a one-line
/// assertion and nothing else in the project would catch it.
@Suite("Recorder settings")
struct RecorderSettingsTests {

    @Test("the format is AAC, not linear PCM")
    func formatIsAAC() {
        #expect(AudioRecorderService.settings[AVFormatIDKey] as? Int == Int(kAudioFormatMPEG4AAC))
    }

    /// The trap: as an Int this key is silently dropped.
    @Test("the sample rate is a Double, because an Int is silently ignored")
    func sampleRateIsDouble() {
        let value = AudioRecorderService.settings[AVSampleRateKey]
        #expect(value is Double, "got \(type(of: value as Any))")
        #expect(value as? Double == 44100.0)
        #expect(!(value is Int))
    }

    @Test("mono, because a pronunciation reference gains nothing from two channels")
    func mono() {
        #expect(AudioRecorderService.settings[AVNumberOfChannelsKey] as? Int == 1)
    }

    @Test("quality and bit rate are set explicitly")
    func qualitySet() {
        #expect(AudioRecorderService.settings[AVEncoderBitRateKey] as? Int == 64_000)
        #expect(AudioRecorderService.settings[AVEncoderAudioQualityKey] as? Int == AVAudioQuality.high.rawValue)
    }

    /// Construction is the check. Note that `recorder.settings` is **empty** until the
    /// recorder has been prepared — verified by probe — so it cannot be used to confirm
    /// that a key was accepted. That is precisely why the type assertions above matter:
    /// there is no round trip to lean on.
    @Test("a recorder can actually be constructed with these settings")
    func constructible() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("oe-settings-check-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = try AVAudioRecorder(url: url, settings: AudioRecorderService.settings)
        #expect(recorder.url == url)
        #expect(recorder.settings.isEmpty,
                "documenting the surprise: settings are not echoed back before preparing")
    }

    @Test("a non-m4a destination is refused, because the extension has to match AAC")
    func extensionMustMatch() async {
        let service = await AudioRecorderService()
        let wrong = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("take.caf")
        await #expect(throws: AppFailure.self) {
            try await service.start(to: wrong)
        }
    }

    @Test("deadlines scale with the work rather than being fixed")
    func deadlinesScale() {
        #expect(Deadlines.recorderFinish == .seconds(5))
        #expect(Deadlines.playerFinish(duration: 60) > Deadlines.playerFinish(duration: 3))
        #expect(Deadlines.recognition(audioDuration: 90) > Deadlines.recognition(audioDuration: 3))
        // A short clip still gets a floor, so a slow machine is not aborted.
        #expect(Deadlines.recognition(audioDuration: 1) == .seconds(15))
    }
}
