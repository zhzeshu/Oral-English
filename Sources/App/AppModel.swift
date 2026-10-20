import Foundation
import Observation

/// The single root object. Views read this and call intents on it; it delegates to the
/// store. No view ever holds the store.
@Observable
@MainActor
public final class AppModel {

    // MARK: - Dependencies

    public let settings: Settings
    public let permissions = PermissionService()
    public let voiceCatalog: VoiceCatalog
    public let practice: PracticeController
    public let recorder = AudioRecorderService()
    public let player = AudioPlayerService()
    public let transcriber = TranscriberService()
    public private(set) var store: PassageStore
    private let lock: LibraryLock

    // MARK: - State

    public var summaries: [PassageSummary] = []
    public var selectedFolder: String?
    public var loaded: LoadedPassage?
    public var granularity: Granularity = .sentence
    public var selectedTarget: TargetRef?
    public var expandedTarget: TargetRef?
    public var searchText: String = ""
    public var banner: BannerKind?
    public var errorMessage: String?
    public var isAnotherInstanceRunning = false
    public var libraryIsSynced = false
    /// True while the speech model download is running, so the banner can say so.
    public private(set) var isInstallingSpeechModel = false

    /// Derived per-row data, recomputed once per passage mutation.
    ///
    /// Rows read only their own summary, so rendering is constant time in take count and
    /// the two array scans never happen in a view body. Revision 1 left this to the final
    /// polish item, by which point the bias was to remove code rather than restructure
    /// data flow.
    public private(set) var rowSummaries: [TargetRef: RowSummary] = [:]

    public struct RowSummary: Sendable, Equatable {
        public var text: String
        public var bestAccuracy: Double?
        public var takeCount: Int
        public var hasMissingAudio: Bool
        public var verdict: AudioQualityVerdict?
        public var problemWords: [String]
        public var heardText: String?
    }

    public init(settings: Settings = Settings()) {
        self.settings = settings
        let provider = AppleVoiceProvider()
        let catalog = VoiceCatalog(provider: provider)
        self.voiceCatalog = catalog
        self.practice = PracticeController(voice: provider)
        self.store = PassageStore(root: settings.libraryRoot)
        self.lock = LibraryLock(libraryRoot: settings.libraryRoot)
    }

    // MARK: - Lifecycle

    public func bootstrap() async {
        guard lock.tryAcquire() else {
            isAnotherInstanceRunning = true
            errorMessage = AppFailure.alreadyRunning.userMessage
            return
        }
        do {
            try await store.ensureLibrary()
            // Status only, no prompt. Nothing asks for a permission at launch.
            permissions.refresh()
            await permissions.refreshModelAvailability()
            await voiceCatalog.refresh()
            voiceNeedsAttention = voiceCatalog.needsBetterVoice
            libraryIsSynced = await store.isInUbiquitousContainer()
            refreshBanner()
            await reloadSummaries()
            if let last = settings.lastPassageFolder,
               summaries.contains(where: { $0.folderName == last }) {
                await select(folderName: last)
            }
        } catch let f as AppFailure {
            Log.failure(Log.app, f, context: "bootstrap")
            errorMessage = f.userMessage
        } catch {
            Log.unexpected(Log.app, error, context: "bootstrap")
            errorMessage = AppFailure.libraryUnavailable(path: settings.libraryRoot.path, underlying: error).userMessage
        }
    }

    public func shutdown() {
        lock.release()
    }

    /// Recomputed from state, with permission problems always outranking advisory notes —
    /// so a dismissed voice nag can never hide a denied microphone.
    public func refreshBanner() {
        var candidates: [BannerKind] = []
        if let p = permissions.matrix.banner { candidates.append(p) }
        if libraryIsSynced { candidates.append(.librarySynced) }
        if voiceNeedsAttention && !settings.voiceBannerDismissed { candidates.append(.voiceQuality) }
        banner = candidates.min()
    }

    public var voiceNeedsAttention = false

    /// The sentences a target covers, so synthesis can speak one per utterance even at
    /// paragraph and whole-passage level.
    public func sentences(for ref: TargetRef) -> [String] {
        guard let loaded else { return [] }
        switch ref.kind {
        case .sentence:
            return loaded.passage.sentence(id: ref.id).map { [$0.text] } ?? []
        case .paragraph:
            guard let p = loaded.passage.paragraph(id: ref.id) else { return [] }
            return p.sentenceIDs.compactMap { loaded.passage.sentence(id: $0)?.text }
        case .passage:
            return loaded.passage.sentences.map(\.text)
        }
    }

    /// The highlight range for a row, in offsets that land on **that row's own text**.
    ///
    /// The controller reports offsets inside the sentence being spoken, because synthesis
    /// runs one utterance per sentence and starts counting again at each one. A sentence
    /// row can use them directly. A paragraph or whole-passage row draws several sentences,
    /// so the offset has to be shifted by where that sentence begins in the row's text —
    /// without the shift every highlight landed inside the first sentence, which read as a
    /// highlight that ran once and then stopped.
    public func spokenRange(for ref: TargetRef) -> (location: Int, length: Int)? {
        guard practice.speakingTarget == ref, let local = practice.spokenRange else { return nil }
        guard let index = practice.spokenSentenceIndex, index > 0 else { return local }
        let starts = sentenceStarts(for: ref)
        guard index < starts.count else { return local }
        return (location: starts[index] + local.location, length: local.length)
    }

    /// Cached per target: the search runs over the whole paragraph, and an uncached call
    /// would repeat it for every word callback and again for every view body.
    private var sentenceStartsCache: (ref: TargetRef, starts: [Int])?

    private func sentenceStarts(for ref: TargetRef) -> [Int] {
        if let cached = sentenceStartsCache, cached.ref == ref { return cached.starts }
        guard let loaded, let text = loaded.passage.text(for: ref) else { return [] }
        let starts = SpokenRange.sentenceStarts(in: text, sentences: sentences(for: ref))
        sentenceStartsCache = (ref, starts)
        return starts
    }

    public func playReference(_ ref: TargetRef) async {
        selectedTarget = ref
        await practice.playReference(
            ref,
            sentences: sentences(for: ref),
            voice: voiceCatalog.resolved(preferred: settings.voiceIdentifier),
            rate: settings.speakingRate
        )
    }

    /// Surfaced for the transient status line. Zero when nothing is recording.
    public var recorderLevel: Double { recorder.level }
    public var recorderElapsed: TimeInterval { recorder.elapsed }
    public var recorderNoInput: Bool { recorder.noInputDetected }

    // MARK: - Recording
    //
    // This is the whole reason the app exists, and until now it was the one thing missing:
    // the recorder was constructed and its level was plumbed into the view, but nothing
    // ever called start or stop, so no take could be created at all. The row showed a mic
    // glyph that was not a button and the empty state advertised a shortcut bound to
    // nothing.
    //
    // The sequence, and why each step is where it is:
    //
    //   1. Ask for permission on the first record tap, never at launch -- a privacy prompt
    //      before the user has done anything reads as an app demanding access.
    //   2. Record into `incoming/`, not into `takes/`. A crash mid-take then leaves an
    //      obvious orphan the store already knows how to adopt, rather than a half take
    //      sitting among the good ones.
    //   3. Judge the finished file with `TakeAcceptance` before it becomes a take.
    //   4. Adopt, append, then score. The take is on disk and visible before scoring
    //      starts, so a recognizer failure loses the score and never the recording.

    /// True while this target is the one being recorded.
    public func isRecording(_ ref: TargetRef) -> Bool { practice.recordingTarget == ref }

    /// One button, two states. The row and ⌘R both route here.
    public func toggleRecording(_ ref: TargetRef) async {
        if practice.recordingTarget == ref {
            await stopRecording()
        } else if practice.recordingTarget == nil {
            await startRecording(ref)
        }
    }

    public func startRecording(_ ref: TargetRef) async {
        guard let folder = selectedFolder, loaded != nil else { return }

        // Asked for here, on the first tap, rather than at launch.
        //
        // The gate is "has this been asked yet", NOT `canRecord`. `canRecord` treats
        // `notDetermined` as available on purpose -- the permission is meant to be
        // requested on the first tap -- so gating the request on `!canRecord` meant the
        // request never ran in exactly the state it exists for. First tap on a fresh
        // install: no dialog, recognition never requested at all, the recorder armed
        // against a microphone with no grant, and a take of silence. That is the whole of
        // "recording is not working".
        var matrix = permissions.matrix
        if permissions.microphone.needsAsking || permissions.recognition.needsAsking {
            matrix = await requestRecordingPermissions()
        }
        guard practice.canRecord(matrix) else {
            if !matrix.canRecord { errorMessage = AppFailure.micDenied.userMessage }
            return
        }

        let id = UUID()
        let staged: URL
        do {
            staged = try await store.stagingURL(in: folder, takeID: id)
        } catch let f as AppFailure {
            errorMessage = f.userMessage
            return
        } catch {
            Log.unexpected(Log.store, error, context: "staging url")
            return
        }

        // The axis is claimed before the hardware starts, so a second tap arriving during
        // `start` cannot open a second recorder.
        guard practice.beginRecording(ref) else { return }
        do {
            try recorder.start(to: staged)
        } catch let f as AppFailure {
            practice.finishRecording()
            Log.failure(Log.audio, f, context: "record start")
            errorMessage = f.userMessage
            // Returning matters: without it a failed start still recorded a pending take,
            // so the next stop would try to adopt a file that was never written.
            return
        } catch {
            practice.finishRecording()
            Log.unexpected(Log.audio, error, context: "record start")
            return
        }
        pendingTake = PendingTake(id: id, target: ref, startedAt: Date())
    }

    /// Finalizes the take, adopts it into the library, then scores it.
    public func stopRecording() async {
        guard let pending = pendingTake, let folder = selectedFolder, let loaded else { return }
        pendingTake = nil

        let result = await recorder.stop()
        practice.finishRecording()

        guard let result else {
            errorMessage = AppFailure.recorderFailedToStart(reason: "no file was produced").userMessage
            return
        }

        let verdict = TakeAcceptance.evaluate(
            duration: result.duration,
            peakLevel: result.peakLevel,
            noInputDetected: recorder.noInputDetected,
            isReadable: result.isReadable)

        if case .discard(let reason) = verdict {
            try? FileManager.default.removeItem(at: result.url)
            errorMessage = reason.note
            return
        }

        // The reference text is captured now, at the moment of recording, so a later edit
        // to the passage cannot retroactively change what this take was scored against.
        guard let referenceText = loaded.passage.text(for: pending.target) else { return }

        let take: Take
        do {
            let relative = try await store.importRecording(
                tempURL: result.url, into: folder,
                target: pending.target, recordedAt: pending.startedAt, takeID: pending.id)
            take = Take(
                id: pending.id,
                target: pending.target,
                recordedAt: pending.startedAt,
                audioPath: relative,
                durationSeconds: result.duration,
                referenceText: referenceText)
            self.loaded = try await store.appendTake(take, to: folder)
            rebuildRowSummaries()
            await reloadSummaries()
        } catch let f as AppFailure {
            Log.failure(Log.store, f, context: "adopt take")
            errorMessage = f.userMessage
            return
        } catch {
            Log.unexpected(Log.store, error, context: "adopt take")
            return
        }

        // Kept, but not scored: an empty transcript scores 0%, which reads as a verdict on
        // the speaker when it is a verdict on the microphone.
        if case .keepWithoutScoring(let reason) = verdict {
            errorMessage = reason.note
            return
        }

        // Scoring reuses rescore, so there is exactly one path from audio to a score.
        await rescore(take)
    }

    /// Stops whatever is happening, finalizing a take if one is in progress.
    ///
    /// The transient transport bar routes its stop button here rather than to
    /// `practice.stopAll()`, which would clear the state and strand the file in `incoming/`.
    public func stopAudio() async {
        if practice.recordingTarget != nil {
            await stopRecording()
        } else {
            practice.stopAll()
            player.stopAll()
        }
    }

    /// Moves anything left in `incoming/` into `recovered/`.
    ///
    /// The library README has promised since it was written that the app "adopts or
    /// quarantines" an interrupted recording on the next launch, and nothing did either --
    /// which mattered little while no code ever wrote to `incoming/`, and matters now that
    /// recording does.
    ///
    /// Quarantine rather than adopt, deliberately. A staged file is named only by its take
    /// id, so which sentence it belongs to is not recoverable from disk; adopting it would
    /// mean inventing a target. Moving it to `recovered/` keeps the audio, keeps the
    /// library honest, and leaves a file the user can play.
    private func sweepInterruptedTakes(in folderName: String) async {
        // Never while a take is in flight: the file being written lives in `incoming/` too.
        guard practice.recordingTarget == nil, pendingTake == nil else { return }
        let pending = await store.pendingIncoming(in: folderName)
        guard !pending.isEmpty else { return }
        var moved = 0
        for url in pending {
            do {
                try await store.quarantineIncoming(url, in: folderName)
                moved += 1
            } catch {
                Log.unexpected(Log.store, error, context: "quarantine incoming")
            }
        }
        guard moved > 0 else { return }
        Log.store.info("quarantined \(moved, privacy: .public) interrupted take(s)")
        errorMessage = moved == 1
            ? "A recording was interrupted last time. It is in the passage's recovered folder."
            : "\(moved) recordings were interrupted last time. They are in the passage's recovered folder."
    }

    /// What is being recorded right now, and where it came from.
    ///
    /// The id and the start time are chosen before recording and reused for the filename,
    /// so the name on disk matches the take it belongs to even if the take is adopted
    /// seconds later.
    private struct PendingTake {
        var id: UUID
        var target: TargetRef
        var startedAt: Date
    }
    private var pendingTake: PendingTake?

    // MARK: - Take actions

    public func playTake(_ take: Take) async {
        guard let loaded, let folder = selectedFolder else { return }
        guard loaded.hasAudio(take) else {
            errorMessage = AppFailure.audioMissing(path: take.audioPath).userMessage
            return
        }
        let url = await store.resolve(relativePath: take.audioPath, in: folder)
        do {
            try await player.play(url, slot: .take, rate: settings.playbackRate)
        } catch let f as AppFailure {
            Log.failure(Log.audio, f, context: "play take")
            errorMessage = f.userMessage
        } catch {
            Log.unexpected(Log.audio, error, context: "play take")
        }
    }

    /// Reference, pause, then your own take — the comparison the row's A/B glyph has always
    /// implied and never performed.
    ///
    /// Sequenced from the two paths that already work rather than through
    /// `AudioPlayerService.playAB`, which wants a baked reference file. Nothing in the app
    /// bakes yet, and speaking the reference live is indistinguishable at this granularity:
    /// synthesis starts in well under the gap that separates the two halves anyway. When
    /// baking arrives this becomes a file-to-file comparison without changing the call.
    public func compareBest(_ ref: TargetRef) async {
        guard let loaded, let take = loaded.bestTake(for: ref) else { return }
        guard practice.audio.isIdle else { return }
        await playReference(ref)
        // Long enough to hear as two separate things, short enough to hold the comparison
        // in your head.
        try? await Task.sleep(for: .milliseconds(400))
        await playTake(take)
    }

    /// Plays your own best take for this target, straight from the row.
    ///
    /// Hearing yourself back is half of what the app is for, and it was reachable only by
    /// opening the take history: the menu advertised "⌘P — play my take" and nothing
    /// implemented it. Reported as "I should be able to press and directly listen to my
    /// speak."
    ///
    /// Best rather than most recent, matching the accuracy shown on the row — the number
    /// and the audio should refer to the same take.
    public func playBestTake(_ ref: TargetRef) async {
        guard let loaded, let take = loaded.bestTake(for: ref) else { return }
        await playTake(take)
    }

    /// True when this target has a take that can be played back right now.
    public func canPlayTake(_ ref: TargetRef) -> Bool {
        guard let loaded, let take = loaded.bestTake(for: ref) else { return false }
        return loaded.hasAudio(take) && practice.audio.isIdle
    }

    /// Moves the selection one row down, wrapping at the end.
    public func selectNextTarget() {
        let targets = visibleTargets
        guard !targets.isEmpty else { return }
        guard let current = selectedTarget, let i = targets.firstIndex(of: current) else {
            selectedTarget = targets.first
            return
        }
        selectedTarget = targets[(i + 1) % targets.count]
    }

    /// True when this target has a take worth comparing against.
    public func canCompare(_ ref: TargetRef) -> Bool {
        guard let loaded, let take = loaded.bestTake(for: ref) else { return false }
        return loaded.hasAudio(take) && practice.audio.isIdle
    }

    public func deleteTake(_ take: Take) async {
        guard let folder = selectedFolder else { return }
        do {
            loaded = try await store.deleteTake(take, in: folder)
            rebuildRowSummaries()
            await reloadSummaries()
        } catch let f as AppFailure {
            errorMessage = f.userMessage
        } catch {
            Log.unexpected(Log.store, error, context: "delete take")
        }
    }

    /// Re-runs the tuned scorer over stored audio.
    ///
    /// This is why keeping every take pays off: tuning improves old results rather than
    /// invalidating them. Reports partial success honestly rather than failing the batch.
    public func rescore(_ take: Take) async {
        guard let folder = selectedFolder, let loaded else { return }
        guard loaded.hasAudio(take) else {
            errorMessage = AppFailure.audioMissing(path: take.audioPath).userMessage
            return
        }
        practice.beginBackgroundWork(take.target)
        defer { practice.endBackgroundWork(take.target) }

        let url = await store.resolve(relativePath: take.audioPath, in: folder)
        do {
            let transcript = try await transcriber.transcribe(fileURL: url)
            let report = Scorer.score(reference: take.referenceText, transcript: transcript)
            self.loaded = try await store.updateScore(report, takeID: take.id, in: folder)
            rebuildRowSummaries()
        } catch let f as AppFailure {
            Log.failure(Log.speech, f, context: "rescore")
            errorMessage = f.userMessage
        } catch {
            Log.unexpected(Log.speech, error, context: "rescore")
        }
    }

    public var activeVoiceName: String? {
        voiceCatalog.resolved(preferred: settings.voiceIdentifier)?.name
    }

    public func selectVoice(_ option: VoiceOption) {
        settings.voiceIdentifier = option.id
    }

    /// Called on the first record tap, never at launch.
    public func requestRecordingPermissions() async -> PermissionMatrix {
        let matrix = await permissions.requestForRecording()
        refreshBanner()
        return matrix
    }

    /// Downloads the on-device speech model.
    ///
    /// This exists because a missing model is not a permission problem, and the banner used
    /// to send the user to the Speech Recognition privacy pane, where there is nothing to
    /// fix. The model is a few hundred megabytes, so the download is explicit and never
    /// implicit in a scoring call.
    public func installSpeechModel() async {
        guard !isInstallingSpeechModel else { return }
        isInstallingSpeechModel = true
        defer { isInstallingSpeechModel = false }
        do {
            try await TranscriberService().installModel()
            await permissions.refreshModelAvailability()
            refreshBanner()
        } catch {
            errorMessage = (error as? AppFailure)?.userMessage
                ?? AppFailure.offlineModelUnavailable(locale: "en-US").userMessage
        }
    }

    /// Re-read on wake: privacy state can change while the machine is asleep.
    ///
    /// The model check is async, so it runs in a follow-up task rather than blocking the
    /// wake path. A model can be removed or a download can finish while asleep, so it does
    /// need re-reading and not just the permission statuses.
    public func permissionsMayHaveChanged() {
        permissions.refresh()
        refreshBanner()
        Task { [weak self] in
            guard let self else { return }
            await permissions.refreshModelAvailability()
            refreshBanner()
        }
    }

    // MARK: - Library

    public func reloadSummaries() async {
        do {
            summaries = try await store.scanSummaries()
        } catch let f as AppFailure {
            Log.failure(Log.store, f, context: "scan")
            errorMessage = f.userMessage
        } catch {
            Log.unexpected(Log.store, error, context: "scan")
        }
    }

    public var filteredSummaries: [PassageSummary] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return summaries }
        return summaries.filter {
            $0.title.lowercased().contains(q) || ($0.theme?.lowercased().contains(q) ?? false)
        }
    }

    /// Grouped under theme headings, untitled themes last.
    public var groupedSummaries: [(theme: String?, items: [PassageSummary])] {
        let items = filteredSummaries
        var order: [String?] = []
        var buckets: [String?: [PassageSummary]] = [:]
        for s in items {
            if buckets[s.theme] == nil { order.append(s.theme); buckets[s.theme] = [] }
            buckets[s.theme]?.append(s)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    public var knownThemes: [String] {
        Array(Set(summaries.compactMap(\.theme))).sorted()
    }

    // MARK: - Selection

    public func select(folderName: String) async {
        selectedFolder = folderName
        settings.lastPassageFolder = folderName
        expandedTarget = nil
        selectedTarget = nil
        sentenceStartsCache = nil
        do {
            loaded = try await store.load(folderName: folderName)
            rebuildRowSummaries()
            await sweepInterruptedTakes(in: folderName)
        } catch let f as AppFailure {
            Log.failure(Log.store, f, context: "load \(folderName)")
            loaded = nil
            rowSummaries = [:]
            errorMessage = f.userMessage
        } catch {
            Log.unexpected(Log.store, error, context: "load \(folderName)")
            loaded = nil
        }
    }

    // MARK: - Intents

    public func createPassage(title: String, theme: String?, text: String) async {
        do {
            let created = try await store.create(title: title, theme: theme, text: text)
            await reloadSummaries()
            await select(folderName: created.folderName)
        } catch let f as AppFailure {
            Log.failure(Log.store, f, context: "create")
            errorMessage = f.userMessage
        } catch {
            Log.unexpected(Log.store, error, context: "create")
        }
    }

    public func deleteSelectedPassage() async {
        guard let folder = selectedFolder else { return }
        do {
            try await store.delete(folderName: folder)
            selectedFolder = nil
            loaded = nil
            rowSummaries = [:]
            await reloadSummaries()
        } catch let f as AppFailure {
            Log.failure(Log.store, f, context: "delete")
            errorMessage = f.userMessage
        } catch {
            Log.unexpected(Log.store, error, context: "delete")
        }
    }

    /// Deletes a row the library could not decode. Operates on the folder name, because
    /// there is no decodable passage to act on — which was the gap in revision 1, where a
    /// broken row could be detected and then never removed.
    public func deleteBroken(_ summary: PassageSummary) async {
        do {
            try await store.delete(folderName: summary.folderName)
            await reloadSummaries()
        } catch let f as AppFailure {
            errorMessage = f.userMessage
        } catch {
            Log.unexpected(Log.store, error, context: "deleteBroken")
        }
    }

    public func rename(to newTitle: String) async {
        guard let folder = selectedFolder else { return }
        do {
            let newFolder = try await store.rename(folderName: folder, to: newTitle)
            await reloadSummaries()
            await select(folderName: newFolder)
        } catch let f as AppFailure {
            errorMessage = f.userMessage
        } catch {
            Log.unexpected(Log.store, error, context: "rename")
        }
    }

    /// Accepts the offer to move the library out of an iCloud-synced Documents folder.
    public func relocateLibraryOutOfSync() async {
        let destination = Paths.applicationSupportLibraryRoot()
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) {
                throw AppFailure.libraryUnavailable(path: destination.path, underlying: nil)
            }
            try fm.moveItem(at: settings.libraryRoot, to: destination)
            settings.libraryPathOverride = destination.path
            store = PassageStore(root: destination)
            libraryIsSynced = false
            banner = nil
            await reloadSummaries()
        } catch let f as AppFailure {
            errorMessage = f.userMessage
        } catch {
            Log.unexpected(Log.store, error, context: "relocate")
            errorMessage = AppFailure.libraryUnavailable(path: destination.path, underlying: error).userMessage
        }
    }

    public func revealInFinder(folderName: String? = nil) {
        let target = folderName ?? selectedFolder
        let url = target.map { settings.libraryRoot.appendingPathComponent($0, isDirectory: true) }
            ?? settings.libraryRoot
        Workspace.reveal(url)
    }

    // MARK: - Row summaries

    public func rebuildRowSummaries() {
        guard let loaded else { rowSummaries = [:]; return }
        var out: [TargetRef: RowSummary] = [:]
        for ref in loaded.passage.allTargets {
            guard let text = loaded.passage.text(for: ref) else { continue }
            let takes = loaded.takes(for: ref)
            let best = loaded.bestTake(for: ref)
            out[ref] = RowSummary(
                text: text,
                bestAccuracy: best?.score?.accuracy,
                takeCount: takes.count,
                hasMissingAudio: takes.contains { !loaded.hasAudio($0) },
                verdict: takes.first?.score?.verdict,
                problemWords: best?.score?.problemWords ?? [],
                heardText: takes.first?.score?.transcript
            )
        }
        rowSummaries = out
    }

    /// Targets for the current granularity, in reading order.
    public var visibleTargets: [TargetRef] {
        guard let loaded else { return [] }
        switch granularity {
        case .sentence: return loaded.passage.sentences.map { .sentence($0.id) }
        case .paragraph: return loaded.passage.paragraphs.map { .paragraph($0.id) }
        case .passage: return [.passage(loaded.passage.id)]
        }
    }

    public var passageBestAccuracy: Double? {
        let values = visibleTargets.compactMap { rowSummaries[$0]?.bestAccuracy }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}
