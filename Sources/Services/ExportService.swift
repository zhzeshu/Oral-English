import AppKit
import Foundation

/// Writes a passage or the whole library to a zip, plus the scores CSV.
///
/// A thin shell: it owns the save dialog and the subprocess, and nothing else. The naming
/// and the CSV are pure functions in `Core/`, so they are covered by the test suite.
@MainActor
public final class ExportService {

    public enum Contents: Sendable {
        /// Everything, including the voice recordings.
        case everything
        /// Transcripts and scores only.
        ///
        /// The likeliest reason to export is showing progress to a teacher, and that is
        /// exactly when you least want to hand over recordings of your voice.
        case transcriptsOnly
    }

    private let store: PassageStore

    public init(store: PassageStore) {
        self.store = store
    }

    // MARK: - Passage export

    public func exportPassage(
        _ loaded: LoadedPassage,
        contents: Contents = .everything
    ) async throws -> URL? {
        // Regenerate the CSV through the store, so it gets the same atomic write as
        // everything else. Writing it directly into the passage folder would contradict
        // the store's own rule and could leave a half-written file on a full disk.
        try await writeScoresCSV(for: loaded)

        let suggested = Paths.passageExportName(
            title: loaded.passage.title,
            theme: loaded.passage.theme,
            createdAt: loaded.passage.createdAt
        )
        guard let destination = await savePanel(suggestedName: suggested) else { return nil }
        try await exportPassage(loaded, to: destination, contents: contents)
        return destination
    }

    /// The same work with an explicit destination, so it can be exercised without a panel.
    public func exportPassage(
        _ loaded: LoadedPassage,
        to destination: URL,
        contents: Contents = .everything
    ) async throws {
        try await writeScoresCSV(for: loaded)
        let folder = await store.folderURL(loaded.folderName)
        try await archive(source: folder, to: destination, contents: contents)
    }

    public func exportLibrary(contents: Contents = .everything) async throws -> URL? {
        let suggested = Paths.libraryExportName(on: Date())
        guard let destination = await savePanel(suggestedName: suggested) else { return nil }
        try await exportLibrary(to: destination, contents: contents)
        return destination
    }

    public func exportLibrary(to destination: URL, contents: Contents = .everything) async throws {
        try await archive(source: store.root, to: destination, contents: contents)
    }

    public func writeScoresCSV(for loaded: LoadedPassage) async throws {
        let csv = ScoreCSV.build(passage: loaded.passage, takes: loaded.takes)
        try await store.writeScoresCSV(csv, in: loaded.folderName)
    }

    // MARK: - Archiving

    private func archive(source: URL, to destination: URL, contents: Contents) async throws {
        // Pre-flight, so a full disk fails before the archive starts rather than leaving a
        // truncated zip the user discovers weeks later.
        let needed = directorySize(source)
        if let available = await store.availableBytes(), available < Int64(Double(needed) * 1.1) {
            throw AppFailure.outOfSpace(neededBytes: needed)
        }

        var stagingToClean: URL?
        defer { if let s = stagingToClean { try? FileManager.default.removeItem(at: s) } }

        var archiveSource = source
        if contents == .transcriptsOnly {
            let staging = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("oral-english-export-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent(source.lastPathComponent, isDirectory: true)
            try copyWithoutAudio(from: source, to: staging)
            archiveSource = staging
            stagingToClean = staging.deletingLastPathComponent()
        }

        try runDitto(source: archiveSource, destination: destination)
    }

    /// `Process` with an argument array, never a shell string.
    ///
    /// Folder names derive from a user-typed title, so a shell string would turn a title
    /// containing a backtick or `$(...)` into command execution. `posix_spawn` with argv
    /// makes those characters inert. The slug also strips them, but relying on two
    /// independent defences is the point.
    private func runDitto(source: URL, destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [
            "-c", "-k", "--sequesterRsrc", "--keepParent",
            source.path, destination.path,
        ]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            throw AppFailure.exportFailed(reason: "the archiver could not be started")
        }

        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let detail = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            Log.export.error("ditto exited \(process.terminationStatus, privacy: .public): \(detail, privacy: .public)")
            // No partial archive left behind.
            try? FileManager.default.removeItem(at: destination)
            throw AppFailure.exportFailed(reason: reason(forDittoStatus: process.terminationStatus, detail: detail))
        }
    }

    private func reason(forDittoStatus status: Int32, detail: String) -> String {
        let lower = detail.lowercased()
        if lower.contains("no space") { return "the disk is full" }
        if lower.contains("permission") || lower.contains("read-only") {
            return "that location is not writable"
        }
        return "the archiver failed"
    }

    /// Copies a passage folder without its audio.
    ///
    /// Uses `subpaths`, which returns paths relative to the base. String-stripping an
    /// absolute prefix breaks here because `/var` is a symlink to `/private/var`, so an
    /// enumerated URL comes back resolved while the base does not — and the result was a
    /// directory literally named `private2026-09-14-...`.
    private func copyWithoutAudio(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for relative in fm.subpaths(atPath: source.path) ?? [] {
            let url = source.appendingPathComponent(relative)
            let target = destination.appendingPathComponent(relative)
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                try? fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else if url.pathExtension.lowercased() != "m4a" {
                try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.copyItem(at: url, to: target)
            }
        }
    }

    private func directorySize(_ url: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in walker {
            total += Int64((try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    // MARK: - Save panel

    private func savePanel(suggestedName: String) async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.zip]
        // Cancelling is not an error.
        return panel.runModal() == .OK ? panel.url : nil
    }
}
