import AVFoundation
import Foundation
import Observation

/// Records a take.
@Observable
@MainActor
public final class AudioRecorderService {

    /// Strong reference required. A recorder held only locally deallocates mid-record.
    private var recorder: AVAudioRecorder?
    private var delegate: RecorderDelegate?
    private var meterTimer: Timer?
    private var silenceSince: Date?

    public private(set) var isRecording = false
    public private(set) var level: Double = 0
    public private(set) var elapsed: TimeInterval = 0
    /// Set when the input has been at the floor long enough to mean something is wrong.
    public private(set) var noInputDetected = false
    /// Highest level seen since `start`. Survives the take, unlike `level`.
    public private(set) var peakLevel: Double = 0

    public init() {}

    /// Exactly these settings.
    ///
    /// Every failure mode here is quiet. Linear PCM with an `.m4a` extension gives an
    /// unplayable file. A mismatched extension makes some readers refuse it. And the sample
    /// rate must be a `Double` — passed as `Int` it is silently ignored, which is asserted
    /// by test because nothing else would catch it.
    /// Computed rather than a stored constant: `[String: Any]` is not `Sendable`, so a
    /// static `let` of that type is rejected under strict concurrency. Building it fresh
    /// each time is free and sidesteps the question entirely.
    public nonisolated static var settings: [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
    }

    public struct Result: Sendable {
        public var url: URL
        public var duration: Double
        /// True when the file was finalized by the delegate rather than salvaged.
        public var wasClean: Bool
        /// True when the finalized file opens as audio. A salvaged take sometimes does not,
        /// and `TakeAcceptance` needs to know rather than guess from the duration.
        public var isReadable: Bool
        /// The highest normalized level seen during the take, 0 through 1.
        ///
        /// Carried on the result because the live `level` is back to zero by the time a
        /// caller inspects it, and the peak is what distinguishes "spoke quietly" from
        /// "microphone is muted".
        public var peakLevel: Double
    }

    // MARK: - Recording

    /// Records to a staging URL the store provides. The recorder never chooses a filename.
    public func start(to url: URL) throws {
        stopMetering()

        // Extension must be .m4a for AAC, or some readers refuse the file.
        guard url.pathExtension.lowercased() == "m4a" else {
            throw AppFailure.recorderFailedToStart(reason: "the file name is not an .m4a")
        }

        let shim = RecorderDelegate(timeout: Deadlines.recorderFinish)
        let recorder: AVAudioRecorder
        do {
            recorder = try AVAudioRecorder(url: url, settings: Self.settings)
        } catch {
            Log.unexpected(Log.audio, error, context: "recorder init")
            throw AppFailure.recorderFailedToStart(reason: "the audio format was rejected")
        }
        recorder.delegate = shim
        recorder.isMeteringEnabled = true

        // prepareToRecord first, or the first take clips its opening word.
        guard recorder.prepareToRecord() else {
            throw AppFailure.recorderFailedToStart(reason: "the recorder could not be prepared")
        }
        // record() returns a Bool that is the only signal for most misconfiguration.
        guard recorder.record() else {
            throw AppFailure.recorderFailedToStart(reason: "the input device refused to start")
        }

        self.recorder = recorder
        self.delegate = shim
        isRecording = true
        noInputDetected = false
        peakLevel = 0
        silenceSince = nil
        startMetering()
    }

    /// Stops and **awaits the finish delegate** before returning.
    ///
    /// `stop()` is asynchronous and the AAC container is finalized in that callback.
    /// Reading the duration or starting transcription earlier gives a zero-byte or
    /// header-less file. On a deadline we salvage whatever bytes exist, because a truncated
    /// take beats nothing.
    public func stop() async -> Result? {
        guard let recorder, let delegate else { return nil }
        let url = recorder.url
        let reportedDuration = recorder.currentTime

        stopMetering()
        recorder.stop()

        var clean = true
        do {
            clean = try await delegate.value()
        } catch {
            clean = false
            Log.audio.error("recorder finish did not arrive; salvaging \(url.lastPathComponent, privacy: .public)")
        }

        self.recorder = nil
        self.delegate = nil
        isRecording = false
        level = 0

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0 else { return nil }

        let file = try? AVAudioFile(forReading: url)
        let duration = file.map { Double($0.length) / $0.fileFormat.sampleRate } ?? reportedDuration

        return Result(url: url, duration: duration, wasClean: clean,
                      isReadable: file != nil, peakLevel: peakLevel)
    }

    public func cancel() {
        stopMetering()
        recorder?.stop()
        recorder?.deleteRecording()
        recorder = nil
        delegate = nil
        isRecording = false
        level = 0
        peakLevel = 0
    }

    // MARK: - Metering

    private func startMetering() {
        // 20 Hz on the main run loop.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func tick() {
        guard let recorder, recorder.isRecording else { return }
        recorder.updateMeters()
        level = AudioLevel.normalized(decibels: Double(recorder.averagePower(forChannel: 0)))
        peakLevel = max(peakLevel, level)
        elapsed = recorder.currentTime

        // Acting on the meter, not just drawing it. One check catches a dead microphone, a
        // hardware-muted one, and a privacy grant that denies without a dialog.
        if AudioLevel.isEffectivelySilent(level) {
            if silenceSince == nil { silenceSince = Date() }
            if let since = silenceSince, Date().timeIntervalSince(since) > AudioLevel.silenceSeconds {
                noInputDetected = true
            }
        } else {
            silenceSince = nil
            noInputDetected = false
        }
    }

    private func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
        silenceSince = nil
        elapsed = 0
    }
}

/// One shim per recording.
private final class RecorderDelegate: NSObject, AVAudioRecorderDelegate, @unchecked Sendable {
    private let shot: OneShot<Bool>

    init(timeout: Duration) {
        self.shot = OneShot(operation: "finishing the recording", timeout: timeout)
        super.init()
    }

    func value() async throws -> Bool { try await shot.value() }

    nonisolated func audioRecorderDidFinishRecording(_ r: AVAudioRecorder, successfully flag: Bool) {
        // successfully: false is a first-class case, distinct from success. The partial file
        // is still imported, because audio the user already spoke must not vanish.
        shot.complete(flag)
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ r: AVAudioRecorder, error: Error?) {
        shot.complete(false)
    }
}
