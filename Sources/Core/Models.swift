import Foundation

// The vocabulary of the app. Every type here is a Codable, Sendable value type, and this
// file imports only Foundation so the test target can compile it.

public let currentSchemaVersion = 1

// MARK: - Granularity and targets

/// What is being practiced. A sentence, a paragraph, or the whole passage.
public enum Granularity: String, Codable, Sendable, CaseIterable, Hashable {
    case sentence
    case paragraph
    case passage
}

/// Names a practice target: a granularity plus a **stable** UUID.
///
/// The id is minted at split time and stored on `Sentence` or `Paragraph`; whole-passage
/// targets carry the passage's own id. It is deliberately never an index — an index would
/// silently re-point every historical take the moment a passage was re-split.
public struct TargetRef: Codable, Sendable, Hashable, Identifiable {
    public var kind: Granularity
    public var id: UUID

    public init(kind: Granularity, id: UUID) {
        self.kind = kind
        self.id = id
    }

    public static func sentence(_ id: UUID) -> TargetRef { .init(kind: .sentence, id: id) }
    public static func paragraph(_ id: UUID) -> TargetRef { .init(kind: .paragraph, id: id) }
    public static func passage(_ id: UUID) -> TargetRef { .init(kind: .passage, id: id) }

    /// Directory component used under `takes/`. Stable across renames.
    public var folderComponent: String { "\(kind.rawValue)/\(id.uuidString.lowercased())" }
}

// MARK: - Passage structure

public struct Sentence: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var index: Int
    public var paragraphIndex: Int
    public var text: String

    public init(id: UUID = UUID(), index: Int, paragraphIndex: Int, text: String) {
        self.id = id
        self.index = index
        self.paragraphIndex = paragraphIndex
        self.text = text
    }
}

public struct Paragraph: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var index: Int
    public var text: String
    public var sentenceIDs: [UUID]

    public init(id: UUID = UUID(), index: Int, text: String, sentenceIDs: [UUID]) {
        self.id = id
        self.index = index
        self.text = text
        self.sentenceIDs = sentenceIDs
    }
}

/// The immutable part of a passage. Takes live in their own files beside the audio, so
/// appending a take never rewrites this.
public struct Passage: Codable, Sendable, Identifiable, Hashable {
    public var schemaVersion: Int
    public var id: UUID
    public var title: String
    public var theme: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var localeIdentifier: String
    public var sourceText: String
    public var paragraphs: [Paragraph]
    public var sentences: [Sentence]

    public init(
        schemaVersion: Int = currentSchemaVersion,
        id: UUID = UUID(),
        title: String,
        theme: String? = nil,
        createdAt: Date,
        updatedAt: Date,
        localeIdentifier: String = "en-US",
        sourceText: String,
        paragraphs: [Paragraph],
        sentences: [Sentence]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.title = title
        self.theme = theme
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.localeIdentifier = localeIdentifier
        self.sourceText = sourceText
        self.paragraphs = paragraphs
        self.sentences = sentences
    }

    public func sentence(id: UUID) -> Sentence? { sentences.first { $0.id == id } }
    public func paragraph(id: UUID) -> Paragraph? { paragraphs.first { $0.id == id } }

    /// The text a target refers to. Whole-passage joins paragraphs with a blank line,
    /// which is why the export CSV must escape embedded newlines.
    public func text(for ref: TargetRef) -> String? {
        switch ref.kind {
        case .sentence: return sentence(id: ref.id)?.text
        case .paragraph: return paragraph(id: ref.id)?.text
        case .passage: return ref.id == id ? paragraphs.map(\.text).joined(separator: "\n\n") : nil
        }
    }

    /// Every target this passage offers, in reading order.
    public var allTargets: [TargetRef] {
        sentences.map { .sentence($0.id) }
            + paragraphs.map { .paragraph($0.id) }
            + [.passage(id)]
    }
}

// MARK: - Transcription

/// One recognized word with the timing and confidence the recognizer reported.
///
/// This type exists because the scorer needs mean confidence. Revision 1 of the plan
/// omitted it, which made the on-disk schema incomplete in a way that would only have
/// surfaced after real user data existed under it.
public struct TranscriptWord: Codable, Sendable, Hashable {
    public var text: String
    public var confidence: Double
    public var startTime: Double
    public var duration: Double

    public init(text: String, confidence: Double, startTime: Double, duration: Double) {
        self.text = text
        self.confidence = confidence
        self.startTime = startTime
        self.duration = duration
    }
}

public struct Transcript: Codable, Sendable, Hashable {
    public var text: String
    public var words: [TranscriptWord]

    public init(text: String, words: [TranscriptWord] = []) {
        self.text = text
        self.words = words
    }

    /// Duration-weighted mean confidence. Zero when nothing was heard.
    public var meanConfidence: Double {
        let totalDuration = words.reduce(0.0) { $0 + max($1.duration, 0) }
        guard totalDuration > 0 else {
            guard !words.isEmpty else { return 0 }
            return words.reduce(0.0) { $0 + $1.confidence } / Double(words.count)
        }
        let weighted = words.reduce(0.0) { $0 + $1.confidence * max($1.duration, 0) }
        return weighted / totalDuration
    }
}

// MARK: - Scoring

public enum WordStatus: String, Codable, Sendable, Hashable {
    case match
    case partial
    case substituted
    case missed
    case extra
}

public struct WordResult: Codable, Sendable, Hashable, Identifiable {
    /// Index into the reference token list, or nil for a word the user inserted.
    public var targetIndex: Int?
    /// Surface form for display, including trailing punctuation.
    public var display: String
    public var normalized: String
    public var heard: String?
    public var status: WordStatus
    public var confidence: Double?

    public var id: String { "\(targetIndex.map(String.init) ?? "x")-\(display)-\(status.rawValue)" }

    public init(
        targetIndex: Int?,
        display: String,
        normalized: String,
        heard: String?,
        status: WordStatus,
        confidence: Double? = nil
    ) {
        self.targetIndex = targetIndex
        self.display = display
        self.normalized = normalized
        self.heard = heard
        self.status = status
        self.confidence = confidence
    }
}

/// How a take's audio quality should be presented, independent of its accuracy.
public enum AudioQualityVerdict: String, Codable, Sendable, Hashable {
    /// Confidence and accuracy both low: show no number, invite a re-record.
    case hardToHear
    /// Confidence low but accuracy acceptable: show the score with a muted note.
    case someWordsHardToHear
    /// Show the score, however low.
    case clear
}

public struct ScoreReport: Codable, Sendable, Hashable {
    public var accuracy: Double
    public var wordErrorRate: Double
    /// The unclamped weighted error. Kept so the over-insertion signal is not lost when
    /// accuracy bottoms out at zero.
    public var rawWeightedError: Double
    public var matchCount: Int
    public var partialCount: Int
    public var substitutionCount: Int
    public var missedCount: Int
    public var extraCount: Int
    public var referenceTokenCount: Int
    public var transcript: String
    public var meanConfidence: Double
    public var verdict: AudioQualityVerdict
    public var engine: String
    public var localeIdentifier: String
    public var scoredAt: Date
    public var words: [WordResult]

    public init(
        accuracy: Double,
        wordErrorRate: Double,
        rawWeightedError: Double,
        matchCount: Int,
        partialCount: Int,
        substitutionCount: Int,
        missedCount: Int,
        extraCount: Int,
        referenceTokenCount: Int,
        transcript: String,
        meanConfidence: Double,
        verdict: AudioQualityVerdict,
        engine: String,
        localeIdentifier: String,
        scoredAt: Date,
        words: [WordResult]
    ) {
        self.accuracy = accuracy
        self.wordErrorRate = wordErrorRate
        self.rawWeightedError = rawWeightedError
        self.matchCount = matchCount
        self.partialCount = partialCount
        self.substitutionCount = substitutionCount
        self.missedCount = missedCount
        self.extraCount = extraCount
        self.referenceTokenCount = referenceTokenCount
        self.transcript = transcript
        self.meanConfidence = meanConfidence
        self.verdict = verdict
        self.engine = engine
        self.localeIdentifier = localeIdentifier
        self.scoredAt = scoredAt
        self.words = words
    }

    /// Words worth practicing again, in reading order, de-duplicated.
    public var problemWords: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for w in words where w.status == .missed || w.status == .substituted {
            if seen.insert(w.display.lowercased()).inserted { out.append(w.display) }
        }
        return out
    }
}

// MARK: - Takes

public struct Take: Codable, Sendable, Identifiable, Hashable {
    public var schemaVersion: Int
    public var id: UUID
    public var target: TargetRef
    public var recordedAt: Date
    /// Relative to the passage folder, always. An absolute path would orphan the audio on
    /// unzip or on any folder move.
    public var audioPath: String
    public var durationSeconds: Double
    /// The reference text as it read when this take was scored, so later edits cannot
    /// retroactively invalidate an old score.
    public var referenceText: String
    public var score: ScoreReport?
    public var note: String?

    public init(
        schemaVersion: Int = currentSchemaVersion,
        id: UUID = UUID(),
        target: TargetRef,
        recordedAt: Date,
        audioPath: String,
        durationSeconds: Double,
        referenceText: String,
        score: ScoreReport? = nil,
        note: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.target = target
        self.recordedAt = recordedAt
        self.audioPath = audioPath
        self.durationSeconds = durationSeconds
        self.referenceText = referenceText
        self.score = score
        self.note = note
    }
}

/// A passage plus its takes, as loaded from disk.
public struct LoadedPassage: Sendable, Hashable {
    public var passage: Passage
    public var takes: [Take]
    /// Folder name on disk, which embeds the date, theme and title.
    public var folderName: String
    /// Take ids whose audio file could not be found. The app disables playback for these
    /// rather than throwing, because the storage folder is deliberately user-editable.
    public var takesMissingAudio: Set<UUID>

    public init(
        passage: Passage,
        takes: [Take],
        folderName: String,
        takesMissingAudio: Set<UUID> = []
    ) {
        self.passage = passage
        self.takes = takes
        self.folderName = folderName
        self.takesMissingAudio = takesMissingAudio
    }

    /// Takes for a target, newest first.
    public func takes(for ref: TargetRef) -> [Take] {
        takes.filter { $0.target == ref }.sorted { $0.recordedAt > $1.recordedAt }
    }

    /// Highest-accuracy take for a target, or nil when none has a score.
    public func bestTake(for ref: TargetRef) -> Take? {
        takes
            .filter { $0.target == ref }
            .compactMap { t -> (Take, Double)? in
                guard let a = t.score?.accuracy, a.isFinite else { return nil }
                return (t, a)
            }
            .max { $0.1 < $1.1 }?
            .0
    }

    public func hasAudio(_ take: Take) -> Bool { !takesMissingAudio.contains(take.id) }
}

/// Cheap sidebar row. Derived at scan time, never written to disk.
public struct PassageSummary: Sendable, Identifiable, Hashable {
    public var id: UUID
    public var folderName: String
    public var title: String
    public var theme: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var sentenceCount: Int
    public var takeCount: Int
    public var averageBestAccuracy: Double?
    /// Set when `passage.json` could not be decoded. The row still appears, carrying the
    /// folder URL and the reason, so the user can act on it.
    public var brokenReason: String?

    public init(
        id: UUID,
        folderName: String,
        title: String,
        theme: String? = nil,
        createdAt: Date,
        updatedAt: Date,
        sentenceCount: Int,
        takeCount: Int,
        averageBestAccuracy: Double? = nil,
        brokenReason: String? = nil
    ) {
        self.id = id
        self.folderName = folderName
        self.title = title
        self.theme = theme
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sentenceCount = sentenceCount
        self.takeCount = takeCount
        self.averageBestAccuracy = averageBestAccuracy
        self.brokenReason = brokenReason
    }

    public var isBroken: Bool { brokenReason != nil }
}

// MARK: - Dates

extension Date {
    /// Truncated to a whole second.
    ///
    /// The `.iso8601` coding strategy writes no fractional seconds, so a `Date` carrying
    /// them does not survive a round trip and an equality assertion fails on two values
    /// that print identically. Encoding fractions instead would work, but whole seconds
    /// keep `passage.json` readable, which is the entire reason for storing it in the open.
    /// Every date entering the model goes through here.
    public var wholeSecond: Date {
        Date(timeIntervalSince1970: (timeIntervalSince1970).rounded(.down))
    }
}

// MARK: - Coding

public enum PassageCoding {
    /// ISO 8601 dates explicitly. The default strategy writes bare numbers, which would
    /// defeat the whole point of human-readable storage.
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Checks the schema version before trusting a decode, so a file from a newer build
    /// reports itself rather than crashing or silently losing fields.
    public static func checkSchemaVersion(in data: Data) throws {
        struct Probe: Decodable { var schemaVersion: Int? }
        let probe: Probe
        do {
            probe = try JSONDecoder().decode(Probe.self, from: data)
        } catch {
            throw AppFailure.passageCorrupt(reason: "not valid JSON", underlying: error)
        }
        guard let v = probe.schemaVersion else {
            throw AppFailure.schemaMissing
        }
        if v > currentSchemaVersion {
            throw AppFailure.schemaTooNew(found: v, supported: currentSchemaVersion)
        }
    }
}
