import Foundation

/// The one failure type for the whole app.
///
/// Revision 1 of the plan had five incompatible failure representations across six work
/// items — a bare `Bool` from the recorder, an `NSError` domain string match from the
/// recognizer, a `Process` exit status from export — and then required uniform one-sentence
/// copy over all of them, via a mapping layer no item owned. One enum with the copy attached
/// makes that requirement testable instead of aspirational.
///
/// Every case carries an optional `underlying` error for the log. The rule is that a catch
/// site logs the full underlying error and shows only `userMessage`.
public enum AppFailure: Error, Sendable {
    // Permissions
    case micDenied
    case recognitionDenied
    case offlineModelUnavailable(locale: String)

    // Recording
    case recorderFailedToStart(reason: String)
    case deviceLost
    case noSpeechDetected
    case outOfSpace(neededBytes: Int64?)

    // Library and storage
    case libraryUnavailable(path: String, underlying: Error?)
    case passageCorrupt(reason: String, underlying: Error?)
    case audioMissing(path: String)
    case schemaTooNew(found: Int, supported: Int)
    case schemaMissing
    case alreadyRunning

    // Long operations
    case timedOut(operation: String, afterSeconds: Double)
    case exportFailed(reason: String)
    case cancelled

    /// One sentence: what happened, then what to do. No raw error text, no first person,
    /// no exclamation marks. Asserted by `AppFailureTests`.
    public var userMessage: String {
        switch self {
        case .micDenied:
            return "Microphone access is off, so recording is unavailable. Turn it on in Privacy settings."
        case .recognitionDenied:
            return "Speech recognition is off, so scoring is unavailable. Recording still works."
        case .offlineModelUnavailable(let locale):
            return "Scoring needs the offline \(locale) speech model. Download it in Language settings."
        case .recorderFailedToStart(let reason):
            return "Recording could not start because \(reason). Check the input device and try again."
        case .deviceLost:
            return "The microphone disconnected. The partial take was kept, so record again when ready."
        case .noSpeechDetected:
            return "Nothing was heard in that take. Move closer to the microphone and record again."
        case .outOfSpace:
            return "There is not enough free space to record. Free some space and try again."
        case .libraryUnavailable(let path, _):
            return "The library folder at \(path) could not be reached. Reveal it in Finder to check."
        case .passageCorrupt(let reason, _):
            return "This passage could not be read because it is \(reason). Reveal it in Finder to repair or remove it."
        case .audioMissing:
            return "The recording for this take is no longer in the folder, so it cannot be played."
        case .schemaTooNew(let found, let supported):
            return "This passage was saved by a newer version, format \(found) rather than \(supported). Update the app to open it."
        case .schemaMissing:
            return "This passage is missing its format version, so it cannot be read. Reveal it in Finder to inspect it."
        case .alreadyRunning:
            return "Oral English is already open. Use the existing window."
        case .timedOut(let operation, let seconds):
            return "\(operation.capitalizedFirst) did not finish within \(Int(seconds)) seconds. Try again."
        case .exportFailed(let reason):
            return "The export could not be written because \(reason). Choose another location and try again."
        case .cancelled:
            return "That was cancelled, so nothing changed."
        }
    }

    /// Present for the log, never for the UI.
    public var underlying: Error? {
        switch self {
        case .libraryUnavailable(_, let e), .passageCorrupt(_, let e): return e
        default: return nil
        }
    }

    /// Short stable key for log lines and metrics.
    public var key: String {
        switch self {
        case .micDenied: return "mic_denied"
        case .recognitionDenied: return "recognition_denied"
        case .offlineModelUnavailable: return "offline_model_unavailable"
        case .recorderFailedToStart: return "recorder_failed_to_start"
        case .deviceLost: return "device_lost"
        case .noSpeechDetected: return "no_speech_detected"
        case .outOfSpace: return "out_of_space"
        case .libraryUnavailable: return "library_unavailable"
        case .passageCorrupt: return "passage_corrupt"
        case .audioMissing: return "audio_missing"
        case .schemaTooNew: return "schema_too_new"
        case .schemaMissing: return "schema_missing"
        case .alreadyRunning: return "already_running"
        case .timedOut: return "timed_out"
        case .exportFailed: return "export_failed"
        case .cancelled: return "cancelled"
        }
    }

    /// Every case, so tests can assert the copy rules across all of them without a
    /// hand-maintained list that drifts.
    public static var allCasesForCopyCheck: [AppFailure] {
        [
            .micDenied,
            .recognitionDenied,
            .offlineModelUnavailable(locale: "en-US"),
            .recorderFailedToStart(reason: "the input device was busy"),
            .deviceLost,
            .noSpeechDetected,
            .outOfSpace(neededBytes: 1024),
            .libraryUnavailable(path: "/tmp/library", underlying: nil),
            .passageCorrupt(reason: "not valid JSON", underlying: nil),
            .audioMissing(path: "takes/a.m4a"),
            .schemaTooNew(found: 2, supported: 1),
            .schemaMissing,
            .alreadyRunning,
            .timedOut(operation: "recording", afterSeconds: 5),
            .exportFailed(reason: "the disk is full"),
            .cancelled,
        ]
    }
}

extension String {
    var capitalizedFirst: String {
        guard let f = first else { return self }
        return String(f).uppercased() + dropFirst()
    }
}
