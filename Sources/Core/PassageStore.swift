import Foundation

/// Owns the folder layout, all JSON, and all file creation, move and delete.
///
/// This lives in `Core/` rather than `Services/` because it needs only Foundation and
/// **must** be compiled by the test target. Revision 1 of the plan placed it under
/// `Services/` while scoping the test target to `Core/`, which meant its eleven test rows —
/// including the two the plan itself called most important — could never have linked.
///
/// The precise invariant, since the looser version was false for five services: the store
/// owns the layout, the JSON, and file creation, move and delete. Other services may open,
/// read and write audio bytes only at URLs the store hands them, and must never construct a
/// path or choose a filename.
public actor PassageStore {

    public let root: URL
    private let fm = FileManager.default

    /// Modification dates seen at load, so a write can detect that something else changed
    /// the file underneath and re-apply rather than overwrite.
    private var seenModificationDates: [String: Date] = [:]

    public init(root: URL = Paths.defaultLibraryRoot()) {
        self.root = root
    }

    // MARK: - Library

    public func folderURL(_ folderName: String) -> URL {
        root.appendingPathComponent(folderName, isDirectory: true)
    }

    /// Creates the library root and its README. Idempotent, and re-asserted before every
    /// write so a folder renamed mid-session surfaces rather than silently recreating an
    /// empty library.
    public func ensureLibrary() throws {
        do {
            if !fm.fileExists(atPath: root.path) {
                try fm.createDirectory(at: root, withIntermediateDirectories: true)
            }
            let readme = root.appendingPathComponent("README.txt", isDirectory: false)
            if !fm.fileExists(atPath: readme.path) {
                try Self.readmeText.write(to: readme, atomically: true, encoding: .utf8)
            }
        } catch {
            throw AppFailure.libraryUnavailable(path: root.path, underlying: error)
        }
    }

    /// Written into the library so the disclosure lives next to the data.
    ///
    /// The review noted that this folder holds recordings of the user's voice, kept until
    /// manually deleted, included in backups, and uploaded if iCloud Desktop and Documents
    /// sync is ever switched on — and that nothing told the user any of that.
    static let readmeText = """
    Oral English — your practice library
    ====================================

    One folder per passage, named with the date, the theme and the title, so sorting by
    name also sorts by date.

    Inside each passage folder:

      passage.json    the text, split into paragraphs and sentences. Plain JSON.
      takes/          one .m4a recording plus one .json score per take, sharing a name.
      reference/      synthesized reference audio, when it has been baked.
      incoming/       a recording interrupted by a crash or a forced quit. The app adopts
                      or quarantines anything here on the next launch.
      recovered/      interrupted recordings that could not be read back.
      scores.csv      regenerated on export, for spreadsheets.

    About the .m4a files
    --------------------

    They are recordings of your voice. They are kept until you delete them, they are
    included in any backup of your Documents folder, and if you turn on iCloud "Desktop &
    Documents Folders" they will be uploaded to iCloud along with everything else here.

    You can delete any take by removing its .m4a and .json pair. The app notices and marks
    that take as having no recording rather than breaking.

    Editing these files by hand is fine. Keep passage.json valid JSON — if it stops being
    valid, the app marks just that one passage as broken and leaves the rest working.
    """

    /// True when the library sits inside an iCloud ubiquitous container.
    ///
    /// Under sync, audio is evicted to dataless placeholders and `replaceItemAt` generates
    /// conflict duplicates. The app offers to relocate rather than relocating silently,
    /// because a browsable Documents folder was the user's explicit choice.
    public func isInUbiquitousContainer() -> Bool {
        (try? root.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true
    }

    // MARK: - Scanning

    /// Folders are the source of truth; there is no index to drift.
    public func scanSummaries() throws -> [PassageSummary] {
        try ensureLibrary()
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )
        } catch {
            throw AppFailure.libraryUnavailable(path: root.path, underlying: error)
        }

        var out: [PassageSummary] = []
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let folderName = entry.lastPathComponent
            // One bad folder must cost one row, never the scan.
            out.append(summary(forFolder: folderName) ?? brokenSummary(folderName, reason: "unreadable"))
        }
        return out.sorted { $0.createdAt > $1.createdAt }
    }

    private func summary(forFolder folderName: String) -> PassageSummary? {
        let folder = folderURL(folderName)
        let jsonURL = Paths.passageJSON(in: folder)
        guard let data = try? Data(contentsOf: jsonURL) else {
            return brokenSummary(folderName, reason: "missing passage.json")
        }
        do {
            try PassageCoding.checkSchemaVersion(in: data)
            let passage = try PassageCoding.decoder().decode(Passage.self, from: data)
            let takes = (try? loadTakes(in: folder)) ?? []
            let loaded = LoadedPassage(passage: passage, takes: takes, folderName: folderName)
            let bests = passage.allTargets.compactMap { loaded.bestTake(for: $0)?.score?.accuracy }
            return PassageSummary(
                id: passage.id, folderName: folderName,
                title: passage.title, theme: passage.theme,
                createdAt: passage.createdAt, updatedAt: passage.updatedAt,
                // Takes on a sentence a revision removed stay on disk but are not shown.
                sentenceCount: passage.sentences.count, takeCount: takes.count - loaded.orphanedTakes.count,
                averageBestAccuracy: bests.isEmpty ? nil : bests.reduce(0, +) / Double(bests.count)
            )
        } catch let f as AppFailure {
            return brokenSummary(folderName, reason: f.key)
        } catch {
            return brokenSummary(folderName, reason: "not valid JSON")
        }
    }

    /// A broken row still carries enough to act on: the folder name is the URL, and the
    /// reason explains itself. Detection without an action was the gap the review found.
    private func brokenSummary(_ folderName: String, reason: String) -> PassageSummary {
        let modified = (try? folderURL(folderName).resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? Date.distantPast
        return PassageSummary(
            id: UUID(), folderName: folderName,
            title: folderName, theme: nil,
            createdAt: modified, updatedAt: modified,
            sentenceCount: 0, takeCount: 0,
            averageBestAccuracy: nil, brokenReason: reason
        )
    }

    // MARK: - Loading

    public func load(folderName: String) throws -> LoadedPassage {
        let folder = folderURL(folderName)
        let jsonURL = Paths.passageJSON(in: folder)

        cleanStaleTempFiles(in: folder)

        let data: Data
        do {
            data = try Data(contentsOf: jsonURL)
        } catch {
            throw AppFailure.passageCorrupt(reason: "missing its passage.json", underlying: error)
        }
        try PassageCoding.checkSchemaVersion(in: data)

        let passage: Passage
        do {
            passage = try PassageCoding.decoder().decode(Passage.self, from: data)
        } catch {
            // Keep the bad file so a stray comma stays hand-fixable, then report.
            quarantineCorruptFile(jsonURL)
            throw AppFailure.passageCorrupt(reason: "not valid JSON", underlying: error)
        }

        seenModificationDates[folderName] = modificationDate(of: jsonURL)

        let takes = try loadTakes(in: folder)
        var missing = Set<UUID>()
        for t in takes {
            let audio = folder.appendingPathComponent(t.audioPath, isDirectory: false)
            if !fm.fileExists(atPath: audio.path) { missing.insert(t.id) }
        }

        return LoadedPassage(passage: passage, takes: takes, folderName: folderName, takesMissingAudio: missing)
    }

    /// One file per take. A corrupt take costs that take, not the session.
    func loadTakes(in folder: URL) throws -> [Take] {
        let dir = Paths.takesDirectory(in: folder)
        guard fm.fileExists(atPath: dir.path) else { return [] }
        let entries = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var out: [Take] = []
        for url in entries where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url) else { continue }
            guard let take = try? PassageCoding.decoder().decode(Take.self, from: data) else {
                Log.store.error("skipping unreadable take file \(url.lastPathComponent, privacy: .public)")
                continue
            }
            out.append(take)
        }
        return out.sorted { $0.recordedAt < $1.recordedAt }
    }

    // MARK: - Creating and deleting

    public func create(title: String, theme: String?, text: String) throws -> LoadedPassage {
        try ensureLibrary()
        let now = Date().wholeSecond
        let split = SentenceSplitter.split(text)
        let passage = Passage(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            theme: theme?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            createdAt: now, updatedAt: now,
            sourceText: TextIntake.clean(text),
            paragraphs: split.paragraphs, sentences: split.sentences
        )
        var folderName = Paths.passageFolderName(
            title: passage.title, theme: passage.theme, createdAt: now, id: passage.id
        )

        // withIntermediateDirectories: false, so an unexpected collision throws instead of
        // silently merging two passages into one folder on a case-insensitive filesystem.
        var attempt = 0
        while true {
            do {
                try fm.createDirectory(at: folderURL(folderName), withIntermediateDirectories: false)
                break
            } catch {
                attempt += 1
                guard attempt < 5 else {
                    throw AppFailure.libraryUnavailable(path: folderURL(folderName).path, underlying: error)
                }
                folderName = Paths.passageFolderName(
                    title: passage.title, theme: passage.theme, createdAt: now, id: UUID()
                )
            }
        }

        try writePassage(passage, folderName: folderName)
        try fm.createDirectory(at: Paths.takesDirectory(in: folderURL(folderName)), withIntermediateDirectories: true)
        return LoadedPassage(passage: passage, takes: [], folderName: folderName)
    }

    /// Moves to the Trash rather than unlinking, because these are the user's recordings.
    public func delete(folderName: String) throws {
        let folder = folderURL(folderName)
        do {
            try fm.trashItem(at: folder, resultingItemURL: nil)
        } catch {
            throw AppFailure.libraryUnavailable(path: folder.path, underlying: error)
        }
        seenModificationDates[folderName] = nil
    }

    /// Renames the folder to match a new title. Callers must ensure no audio is in flight.
    public func rename(folderName: String, to newTitle: String) throws -> String {
        var loaded = try load(folderName: folderName)
        loaded.passage.title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        loaded.passage.updatedAt = Date().wholeSecond
        let newFolder = Paths.passageFolderName(
            title: loaded.passage.title, theme: loaded.passage.theme,
            createdAt: loaded.passage.createdAt, id: loaded.passage.id
        )
        if newFolder != folderName {
            do {
                try fm.moveItem(at: folderURL(folderName), to: folderURL(newFolder))
            } catch {
                throw AppFailure.libraryUnavailable(path: folderURL(newFolder).path, underlying: error)
            }
            seenModificationDates[folderName] = nil
        }
        try writePassage(loaded.passage, folderName: newFolder)
        return newFolder
    }

    /// Replaces the passage's text, title and theme, carrying sentence and paragraph ids
    /// over so takes stay attached. See `PassageRevision` for the matching. Callers must
    /// ensure no audio is in flight, as for `rename`.
    ///
    /// Takes on removed sentences are left in `takes/` untouched: recordings are only ever
    /// deleted by the user.
    ///
    /// Reads `passage.json` fresh inside the actor and writes it directly, not through
    /// `writePassage`, whose changed-underneath merge keeps only title and theme and would
    /// silently drop the new text.
    public func revise(folderName: String, title: String, theme: String?, text: String) throws -> LoadedPassage {
        try ensureLibrary()
        let current = try loadPassageOnly(folderName: folderName)
        let revision = PassageRevision(from: current, to: text)
        guard !revision.sentences.isEmpty else { throw AppFailure.cancelled }

        var passage = revision.applied(to: current, at: Date())
        passage.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        passage.theme = theme?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        let newFolder = Paths.passageFolderName(
            title: passage.title, theme: passage.theme, createdAt: passage.createdAt, id: passage.id
        )
        if newFolder != folderName {
            do {
                try fm.moveItem(at: folderURL(folderName), to: folderURL(newFolder))
            } catch {
                throw AppFailure.libraryUnavailable(path: folderURL(newFolder).path, underlying: error)
            }
            seenModificationDates[folderName] = nil
        }
        let url = Paths.passageJSON(in: folderURL(newFolder))
        try writeAtomically(try PassageCoding.encoder().encode(passage), to: url)
        seenModificationDates[newFolder] = modificationDate(of: url)
        return try load(folderName: newFolder)
    }

    // MARK: - Takes

    /// Adopts a finalized recording from wherever the recorder staged it, and returns the
    /// relative path. The recorder never chooses a filename.
    public func importRecording(
        tempURL: URL,
        into folderName: String,
        target: TargetRef,
        recordedAt: Date,
        takeID: UUID
    ) throws -> String {
        let folder = folderURL(folderName)
        let takesDir = Paths.takesDirectory(in: folder)
        try? fm.createDirectory(at: takesDir, withIntermediateDirectories: true)

        let relative = Paths.takeAudioRelativePath(recordedAt: recordedAt, id: takeID)
        let destination = folder.appendingPathComponent(relative, isDirectory: false)
        do {
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: tempURL, to: destination)
        } catch {
            throw AppFailure.libraryUnavailable(path: destination.path, underlying: error)
        }
        return relative
    }

    /// Delta-shaped: reads current state inside the actor and writes one small file.
    ///
    /// There is deliberately no `save(_ passage:)`. That shape invites a caller to hold a
    /// stale copy and write it back, dropping a concurrent update — which is the real lost
    /// update the review identified, one layer above the actor.
    public func appendTake(_ take: Take, to folderName: String) throws -> LoadedPassage {
        try ensureLibrary()
        let folder = folderURL(folderName)
        try? fm.createDirectory(at: Paths.takesDirectory(in: folder), withIntermediateDirectories: true)
        let relative = Paths.takeJSONRelativePath(recordedAt: take.recordedAt, id: take.id)
        try writeAtomically(try PassageCoding.encoder().encode(take),
                            to: folder.appendingPathComponent(relative, isDirectory: false))
        try touchPassage(folderName: folderName)
        return try load(folderName: folderName)
    }

    public func updateScore(
        _ score: ScoreReport,
        takeID: UUID,
        in folderName: String
    ) throws -> LoadedPassage {
        let folder = folderURL(folderName)
        let takes = try loadTakes(in: folder)
        guard var take = takes.first(where: { $0.id == takeID }) else {
            throw AppFailure.passageCorrupt(reason: "missing the take being scored", underlying: nil)
        }
        take.score = score
        let relative = Paths.takeJSONRelativePath(recordedAt: take.recordedAt, id: take.id)
        try writeAtomically(try PassageCoding.encoder().encode(take),
                            to: folder.appendingPathComponent(relative, isDirectory: false))
        try touchPassage(folderName: folderName)
        return try load(folderName: folderName)
    }

    public func deleteTake(_ take: Take, in folderName: String) throws -> LoadedPassage {
        let folder = folderURL(folderName)
        let json = folder.appendingPathComponent(
            Paths.takeJSONRelativePath(recordedAt: take.recordedAt, id: take.id), isDirectory: false)
        let audio = folder.appendingPathComponent(take.audioPath, isDirectory: false)
        try? fm.trashItem(at: json, resultingItemURL: nil)
        try? fm.trashItem(at: audio, resultingItemURL: nil)
        return try load(folderName: folderName)
    }

    /// Routed through the store so it gets the same atomic write as everything else.
    /// Writing it directly from the export service would contradict the store's own rule
    /// and could leave a half-written file on a full disk.
    public func writeScoresCSV(_ csv: String, in folderName: String) throws {
        let url = folderURL(folderName).appendingPathComponent("scores.csv", isDirectory: false)
        try writeAtomically(Data(csv.utf8), to: url)
    }

    /// Absolute URL for a stored relative path. Services read and write bytes only here.
    public func resolve(relativePath: String, in folderName: String) -> URL {
        folderURL(folderName).appendingPathComponent(relativePath, isDirectory: false)
    }

    public func stagingURL(in folderName: String, takeID: UUID) throws -> URL {
        let dir = Paths.incomingDirectory(in: folderURL(folderName))
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(takeID.uuidString.lowercased()).m4a", isDirectory: false)
    }

    /// Anything left in `incoming/` is an interrupted take.
    public func pendingIncoming(in folderName: String) -> [URL] {
        let dir = Paths.incomingDirectory(in: folderURL(folderName))
        guard fm.fileExists(atPath: dir.path) else { return [] }
        return ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension == "m4a" }
    }

    public func quarantineIncoming(_ url: URL, in folderName: String) throws {
        let dir = Paths.recoveredDirectory(in: folderURL(folderName))
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(url.lastPathComponent, isDirectory: false)
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: url, to: dest)
    }

    // MARK: - Writing

    private func touchPassage(folderName: String) throws {
        var loaded = try loadPassageOnly(folderName: folderName)
        loaded.updatedAt = Date().wholeSecond
        try writePassage(loaded, folderName: folderName)
    }

    func loadPassageOnly(folderName: String) throws -> Passage {
        let url = Paths.passageJSON(in: folderURL(folderName))
        guard let data = try? Data(contentsOf: url) else {
            throw AppFailure.passageCorrupt(reason: "missing its passage.json", underlying: nil)
        }
        try PassageCoding.checkSchemaVersion(in: data)
        do {
            return try PassageCoding.decoder().decode(Passage.self, from: data)
        } catch {
            throw AppFailure.passageCorrupt(reason: "not valid JSON", underlying: error)
        }
    }

    func writePassage(_ passage: Passage, folderName: String) throws {
        let url = Paths.passageJSON(in: folderURL(folderName))

        // Compare-and-swap against what we last read. If something else wrote the file in
        // between — another instance, or the user's text editor — reload and re-apply
        // rather than overwriting their change.
        if let seen = seenModificationDates[folderName],
           let current = modificationDate(of: url),
           current > seen {
            Log.store.notice("passage.json changed underneath; merging rather than overwriting")
            if var current = try? loadPassageOnly(folderName: folderName) {
                current.title = passage.title
                current.theme = passage.theme
                current.updatedAt = passage.updatedAt
                try writeAtomically(try PassageCoding.encoder().encode(current), to: url)
                seenModificationDates[folderName] = modificationDate(of: url)
                return
            }
        }

        try writeAtomically(try PassageCoding.encoder().encode(passage), to: url)
        seenModificationDates[folderName] = modificationDate(of: url)
    }

    /// Temp file in the same directory, then `replaceItemAt`. A crash mid-write would
    /// otherwise truncate the file and lose a session.
    func writeAtomically(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw AppFailure.libraryUnavailable(path: dir.path, underlying: error)
        }

        let temp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp", isDirectory: false)
        do {
            try data.write(to: temp, options: .atomic)
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: url)
            }
        } catch {
            try? fm.removeItem(at: temp)
            if (error as NSError).code == NSFileWriteOutOfSpaceError {
                throw AppFailure.outOfSpace(neededBytes: Int64(data.count))
            }
            throw AppFailure.libraryUnavailable(path: url.path, underlying: error)
        }
    }

    /// A temp file from a previous crashed run must not be mistaken for anything.
    func cleanStaleTempFiles(in folder: URL) {
        for dir in [folder, Paths.takesDirectory(in: folder)] {
            let entries = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [])) ?? []
            for url in entries where url.pathExtension == "tmp" {
                try? fm.removeItem(at: url)
                Log.store.notice("removed stale temp file \(url.lastPathComponent, privacy: .public)")
            }
        }
    }

    private func quarantineCorruptFile(_ url: URL) {
        let stamp = Paths.takeTimestampFormatter().string(from: Date())
        let dest = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).broken-\(stamp)", isDirectory: false)
        try? fm.copyItem(at: url, to: dest)
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    // MARK: - Free space

    public func availableBytes() -> Int64? {
        guard let v = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) else { return nil }
        return v.volumeAvailableCapacityForImportantUsage
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
