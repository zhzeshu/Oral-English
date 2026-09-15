import AVFoundation
import Foundation
import Speech

/// Turns a recorded take into a transcript, entirely on this machine.
///
/// The only file that knows `Speech` exists.
@MainActor
public final class TranscriberService {

    /// Pinned, not taken from the system.
    ///
    /// Verified: `en-GB`, `en-AU` and `zh-CN` all report available while having **no**
    /// on-device model. Since there is deliberately no server fallback, any of them would
    /// leave scoring silently unavailable. This is an American English trainer, so the
    /// locale is a product decision rather than a system setting.
    public static let locale = Locale(identifier: "en-US")

    public init() {}

    public func transcribe(fileURL: URL) async throws -> Transcript {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw AppFailure.audioMissing(path: fileURL.lastPathComponent)
        }
        guard let recognizer = SFSpeechRecognizer(locale: Self.locale) else {
            throw AppFailure.offlineModelUnavailable(locale: Self.locale.identifier)
        }
        guard recognizer.supportsOnDeviceRecognition else {
            // Never a silent server fallback: local-only is a hard requirement, and a
            // silent fallback would violate it invisibly.
            throw AppFailure.offlineModelUnavailable(locale: Self.locale.identifier)
        }

        let duration = audioDuration(of: fileURL)

        // Short clips take the simple path. Longer audio must be chunked, because a single
        // request has historically capped out near a minute and a whole passage easily runs
        // to ninety seconds.
        if duration <= ChunkPlan.singleRequestLimit {
            return try await transcribeWhole(fileURL, recognizer: recognizer, duration: duration)
        }
        return try await transcribeChunked(fileURL, recognizer: recognizer, duration: duration)
    }

    // MARK: - Single request

    private func transcribeWhole(
        _ url: URL, recognizer: SFSpeechRecognizer, duration: Double
    ) async throws -> Transcript {
        let request = SFSpeechURLRecognitionRequest(url: url)
        configure(request)
        return try await run(request, recognizer: recognizer, duration: duration)
    }

    // MARK: - Chunked

    private func transcribeChunked(
        _ url: URL, recognizer: SFSpeechRecognizer, duration: Double
    ) async throws -> Transcript {
        let plan = ChunkPlan.plan(totalDuration: duration, quietPoints: [])
        var pieces: [(chunk: ChunkPlan.Chunk, transcript: Transcript)] = []

        for chunk in plan {
            let request = SFSpeechAudioBufferRecognitionRequest()
            configure(request)
            try feed(url: url, chunk: chunk, into: request)
            request.endAudio()
            let piece = try await run(request, recognizer: recognizer, duration: chunk.duration)
            pieces.append((chunk, piece))
        }

        // Splicing offsets each chunk's timings by its start. Without that every chunk
        // restarts at zero and the timings are silently meaningless.
        return ChunkPlan.splice(pieces)
    }

    /// Reads one chunk and converts it to the recognizer's format before appending.
    ///
    /// The conversion is not optional. Recordings are 44100 Hz interleaved from file;
    /// synthesis produces 22050 Hz non-interleaved; and the recognizer takes its format
    /// from the buffers it is given. A mismatch produces gibberish, which the scorer then
    /// reports as terrible pronunciation — a wrong score the user would trust.
    private func feed(url: URL, chunk: ChunkPlan.Chunk, into request: SFSpeechAudioBufferRecognitionRequest) throws {
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        let sampleRate = sourceFormat.sampleRate

        let startFrame = AVAudioFramePosition(chunk.start * sampleRate)
        let frameCount = AVAudioFrameCount(chunk.duration * sampleRate)
        guard startFrame < file.length else { return }
        file.framePosition = startFrame

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else { return }

        let converter = AVAudioConverter(from: sourceFormat, to: target)
        let bufferSize: AVAudioFrameCount = 8192
        var remaining = frameCount

        while remaining > 0 {
            let thisPass = min(bufferSize, remaining)
            guard let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: thisPass) else { break }
            try file.read(into: input, frameCount: thisPass)
            if input.frameLength == 0 { break }
            remaining -= input.frameLength

            if sourceFormat == target || converter == nil {
                request.append(input)
                continue
            }
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: input.frameLength) else { break }
            var error: NSError?
            // AVAudioPCMBuffer is not Sendable and the input block is marked @Sendable, but
            // the block is invoked synchronously by `convert` on this thread and does not
            // outlive the call, so nothing actually crosses a boundary. The one-shot flag
            // lives in a reference box for the same reason: a captured `var` in a
            // @Sendable closure is a warning even when the closure is synchronous.
            let feed = SingleBufferFeed(buffer: input)
            converter?.convert(to: output, error: &error, withInputFrom: feed.block)
            if error == nil, output.frameLength > 0 {
                request.append(output)
            }
        }
    }

    // MARK: - Running a request

    private func configure(_ request: SFSpeechRecognitionRequest) {
        // Forced, since local-only was a requirement.
        request.requiresOnDeviceRecognition = true
        // Punctuation is noise for word comparison.
        request.addsPunctuation = false
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
    }

    private func run(
        _ request: SFSpeechRecognitionRequest,
        recognizer: SFSpeechRecognizer,
        duration: Double
    ) async throws -> Transcript {
        let shot = OneShot<Transcript>(
            operation: "scoring the take",
            timeout: Deadlines.recognition(audioDuration: duration)
        )

        // SFSpeechRecognitionResult and SFTranscriptionSegment are not Sendable, so they
        // are mapped into plain value types INSIDE the closure, before the continuation
        // resumes. Applied mechanically, that one rule eliminates the whole class of
        // Swift 6 errors here.
        let task = recognizer.recognitionTask(with: request) { result, error in
            if let error {
                shot.fail(Self.map(error))
                return
            }
            guard let result, result.isFinal else { return }
            let best = result.bestTranscription
            let words = best.segments.map {
                TranscriptWord(
                    text: $0.substring,
                    confidence: Double($0.confidence),
                    startTime: $0.timestamp,
                    duration: $0.duration
                )
            }
            shot.complete(Transcript(text: best.formattedString, words: words))
        }

        do {
            return try await shot.value()
        } catch {
            task.cancel()
            throw error
        }
    }

    /// Errors that must not look like failures.
    static func map(_ error: Error) -> AppFailure {
        let ns = error as NSError
        // The common one: a clipped or silent take. Never a dialog, never a zero score.
        if ns.domain == "kAFAssistantErrorDomain" && ns.code == 1110 {
            return .noSpeechDetected
        }
        if ns.domain == "kAFAssistantErrorDomain" && ns.code == 1101 {
            return .offlineModelUnavailable(locale: locale.identifier)
        }
        if ns.code == NSFileReadNoSuchFileError {
            return .audioMissing(path: "the recording")
        }
        Log.unexpected(Log.speech, error, context: "recognition")
        return .exportFailed(reason: "the recognizer stopped unexpectedly")
    }

    /// Hands one buffer to `AVAudioConverter`, then reports no more data.
    private final class SingleBufferFeed: @unchecked Sendable {
        private let buffer: AVAudioPCMBuffer
        private var supplied = false

        init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }

        var block: AVAudioConverterInputBlock {
            { [self] _, status in
                if supplied {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
        }
    }

    private func audioDuration(of url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }
}
