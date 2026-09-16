import AVFoundation
import Foundation
import Speech

/// Turns a recorded take into a transcript, entirely on this machine.
///
/// The only file that knows `Speech` exists.
///
/// ## Why this uses `SpeechAnalyzer` and not `SFSpeechRecognizer`
///
/// Measured on this machine, 2026-09-15, macOS 26.6.1: legacy `SFSpeechRecognizer` with
/// `requiresOnDeviceRecognition = true` returns an **empty final result with zero segments
/// and no error** in about 0.2 seconds, for audio measured at −21.4 dBFS RMS containing
/// clear speech. It does this with the grant given, with `isAvailable` true, with
/// `supportsOnDeviceRecognition` true, with the en-US model installed, and for both AAC
/// `.m4a` and 16-bit PCM WAV of identical audio. The modern API transcribes the same file
/// correctly in the same session.
///
/// So this is not a preference. There is no working legacy path on this OS, which is why
/// no fallback is kept: a fallback would be untested code that is known-broken exactly
/// where it would run. The deployment target was raised to macOS 26.0 for this.
///
/// Full account in `docs/plan/10-transcription.md`.
@MainActor
public final class TranscriberService {

    /// Pinned, not taken from the system.
    ///
    /// This is an American English trainer, so the locale is a product decision rather than
    /// a system setting. Verified: other English locales and `zh-CN` report available while
    /// having no on-device model, and since there is deliberately no server fallback, any of
    /// them would leave scoring silently unavailable.
    public static let locale = Locale(identifier: "en-US")

    /// Recorded on every score, so a result can be traced to what produced it.
    public static let engine = "SpeechAnalyzer/SpeechTranscriber"

    public init() {}

    // MARK: - Model availability

    /// Whether the on-device model this service needs is actually installed.
    ///
    /// Read this rather than `SFSpeechRecognizer.supportsOnDeviceRecognition`, which reports
    /// *capability* and was true on this machine while nothing could transcribe. Note also
    /// that `SpeechTranscriber.installedLocales` claimed en-US was installed at the same
    /// time `AssetInventory.status` said only `.supported` — including for a module with no
    /// attribute options. `AssetInventory.status` is the signal that matched reality.
    public static func modelStatus() async -> AssetInventory.Status {
        await AssetInventory.status(forModules: [makeTranscriber()])
    }

    /// Downloads and installs the on-device model.
    ///
    /// Deliberately separate from `transcribe`, and never implicit: the model is a few
    /// hundred megabytes, so starting a download is a decision the UI must surface rather
    /// than something a scoring call does behind the user's back.
    public func installModel() async throws {
        do {
            guard let request = try await AssetInventory.assetInstallationRequest(
                supporting: [Self.makeTranscriber()]) else { return }
            try await request.downloadAndInstall()
        } catch {
            Log.unexpected(Log.speech, error, context: "installing the speech model")
            throw AppFailure.offlineModelUnavailable(locale: Self.locale.identifier)
        }
    }

    /// One transcriber, configured identically everywhere.
    ///
    /// `attributeOptions` is load-bearing. Without `.transcriptionConfidence` the results
    /// carry **no confidence at all** — verified: the same audio returned one run with no
    /// confidence attribute under base options, and eight runs each carrying confidence once
    /// it was requested. Item 03's hard-to-hear rule depends on that value, and
    /// `.audioTimeRange` is what gives each word its timing.
    private static func makeTranscriber() -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.transcriptionConfidence, .audioTimeRange])
    }

    // MARK: - Transcribing

    public func transcribe(fileURL: URL) async throws -> Transcript {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw AppFailure.audioMissing(path: fileURL.lastPathComponent)
        }
        guard SpeechTranscriber.isAvailable else {
            throw AppFailure.offlineModelUnavailable(locale: Self.locale.identifier)
        }

        let transcriber = Self.makeTranscriber()

        // Never download implicitly. A missing model is a UI state, not a scoring failure to
        // paper over, so it surfaces as the same failure the banner already understands.
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw AppFailure.offlineModelUnavailable(locale: Self.locale.identifier)
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: fileURL)
        } catch {
            throw AppFailure.audioMissing(path: fileURL.lastPathComponent)
        }
        let duration = Double(file.length) / file.fileFormat.sampleRate

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Results must be consumed concurrently with analysis. Draining afterwards
        // deadlocks: the analyzer will not finish until the results are taken.
        let collector = Task { () throws -> [TranscriptWord] in
            var words: [TranscriptWord] = []
            for try await result in transcriber.results {
                let text = result.text
                for run in text.runs {
                    let piece = String(text[run.range].characters)
                    guard !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        continue
                    }
                    let range = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self]
                    words.append(TranscriptWord(
                        text: piece,
                        confidence: run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] ?? 0,
                        startTime: range.map { $0.start.seconds } ?? 0,
                        duration: range.map { $0.duration.seconds } ?? 0))
                }
            }
            return words
        }

        // The deadline the plan requires, kept for the same reason as the delegate shims:
        // every control binds to the activity state, so an operation that never returns
        // disables the app until force quit. This watchdog cancels the analyzer rather than
        // abandoning it, so the results stream terminates and `collector` completes.
        let timedOut = Flag()
        let watchdog = Task {
            try? await Task.sleep(for: Deadlines.recognition(audioDuration: duration))
            guard !Task.isCancelled else { return }
            timedOut.set()
            await analyzer.cancelAndFinishNow()
        }

        let words: [TranscriptWord]
        do {
            _ = try await analyzer.analyzeSequence(from: file)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            words = try await collector.value
            watchdog.cancel()
        } catch {
            watchdog.cancel()
            collector.cancel()
            if timedOut.isSet {
                throw AppFailure.timedOut(
                    operation: "scoring the take",
                    afterSeconds: duration * 2 + 15)
            }
            throw Self.map(error)
        }

        if timedOut.isSet {
            throw AppFailure.timedOut(
                operation: "scoring the take",
                afterSeconds: duration * 2 + 15)
        }

        let text = words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)

        // A silent or clipped take is not a zero score. The plan is explicit: never a
        // dialog and never a zero, because a zero reads as a verdict on the speaker when it
        // is a verdict on the audio.
        guard !text.isEmpty else { throw AppFailure.noSpeechDetected }

        return Transcript(text: text, words: words)
    }

    // MARK: - Errors that must not look like failures

    static func map(_ error: Error) -> AppFailure {
        if let failure = error as? AppFailure { return failure }
        let ns = error as NSError
        // Retained from the legacy path: these codes still surface from the Speech stack,
        // and a clipped or silent take must read as "I could not hear anything".
        if ns.domain == "kAFAssistantErrorDomain" && ns.code == 1110 {
            return .noSpeechDetected
        }
        if ns.domain == "kAFAssistantErrorDomain" && ns.code == 1101 {
            return .offlineModelUnavailable(locale: locale.identifier)
        }
        if ns.code == NSFileReadNoSuchFileError {
            return .audioMissing(path: "the recording")
        }
        if error is CancellationError {
            return .cancelled
        }
        Log.unexpected(Log.speech, error, context: "recognition")
        return .exportFailed(reason: "the recognizer stopped unexpectedly")
    }

    /// A one-way flag readable from the `@MainActor` body and settable from the watchdog.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }
}
