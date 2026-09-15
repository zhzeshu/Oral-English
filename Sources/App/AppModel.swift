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

    /// Set by the voice catalog in item 07.
    public var voiceNeedsAttention = false

    /// Called on the first record tap, never at launch.
    public func requestRecordingPermissions() async -> PermissionMatrix {
        let matrix = await permissions.requestForRecording()
        refreshBanner()
        return matrix
    }

    /// Re-read on wake: privacy state can change while the machine is asleep.
    public func permissionsMayHaveChanged() {
        permissions.refresh()
        refreshBanner()
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
        do {
            loaded = try await store.load(folderName: folderName)
            rebuildRowSummaries()
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
