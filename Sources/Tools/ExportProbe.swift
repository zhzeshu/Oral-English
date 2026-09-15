import AppKit
import Foundation

// Exercises the archive path end to end without the save panel: real ditto, real zip, real
// unzip, against a temporary library.

@main
struct ExportProbe {
    @MainActor
    static func main() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("oral-english-export-probe-\(UUID().uuidString)", isDirectory: true)
        let out = root.deletingLastPathComponent()
            .appendingPathComponent("oe-export-out-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root); try? fm.removeItem(at: out) }

        let store = PassageStore(root: root)
        let text = "The fog came in. It sat looking over harbor, and city.\n\nThen it moved on."
        let created = try await store.create(title: "The fog came in", theme: "Interview prep", text: text)

        // Two takes with real bytes on disk, one scored.
        let ref = TargetRef.sentence(created.passage.sentences[0].id)
        for i in 0..<2 {
            let id = UUID()
            let when = Date().addingTimeInterval(Double(i) * 60).wholeSecond
            let staged = try await store.stagingURL(in: created.folderName, takeID: id)
            try Data(repeating: 0x41, count: 4096).write(to: staged)
            let rel = try await store.importRecording(
                tempURL: staged, into: created.folderName, target: ref, recordedAt: when, takeID: id)
            var score: ScoreReport?
            if i == 0 {
                let t = Transcript(text: "the fog came in", words: [
                    TranscriptWord(text: "the", confidence: 0.9, startTime: 0, duration: 1),
                ])
                score = Scorer.score(reference: created.passage.sentences[0].text, transcript: t)
            }
            _ = try await store.appendTake(
                Take(id: id, target: ref, recordedAt: when, audioPath: rel, durationSeconds: 3.4,
                     referenceText: created.passage.sentences[0].text, score: score),
                to: created.folderName)
        }

        let loaded = try await store.load(folderName: created.folderName)
        let service = ExportService(store: store)

        // 1. Full export.
        let fullZip = out.appendingPathComponent(Paths.passageExportName(
            title: loaded.passage.title, theme: loaded.passage.theme,
            createdAt: loaded.passage.createdAt))
        try await service.exportPassage(loaded, to: fullZip, contents: .everything)
        print("full export name: \(fullZip.lastPathComponent)")
        print("  exists: \(fm.fileExists(atPath: fullZip.path)), size: \((try? fullZip.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) bytes")

        let unzipped = out.appendingPathComponent("unzipped", isDirectory: true)
        try run("/usr/bin/ditto", ["-x", "-k", fullZip.path, unzipped.path])
        // subpaths returns paths relative to the base already, which avoids the
        // /var versus /private/var symlink trap that string-stripping walks into.
        let listing = (fm.subpaths(atPath: unzipped.path) ?? []).sorted()
        print("  unzipped contents:")
        for l in listing { print("    \(l)") }

        let audioCount = listing.filter { $0.hasSuffix(".m4a") }.count
        let hasCSV = listing.contains { $0.hasSuffix("scores.csv") }
        let hasJSON = listing.contains { $0.hasSuffix("passage.json") }
        print("  audio files: \(audioCount), scores.csv: \(hasCSV), passage.json: \(hasJSON)")

        // Audio still plays back as the same bytes.
        if let audio = listing.first(where: { $0.hasSuffix(".m4a") }) {
            let data = try Data(contentsOf: unzipped.appendingPathComponent(audio))
            print("  first audio file is \(data.count) bytes after the round trip")
        }

        // CSV parses and has the rows.
        if hasCSV, let csvURL = listing.first(where: { $0.hasSuffix("scores.csv") }) {
            let csv = try String(contentsOf: unzipped.appendingPathComponent(csvURL), encoding: .utf8)
            let rows = ScoreCSV.parse(csv)
            print("  scores.csv: \(rows.count) rows (header plus \(rows.count - 1) takes), \(rows.first?.count ?? 0) columns")
        }

        // 2. Transcripts-only export.
        let leanZip = out.appendingPathComponent("lean.zip")
        try await service.exportPassage(loaded, to: leanZip, contents: .transcriptsOnly)
        let leanOut = out.appendingPathComponent("lean", isDirectory: true)
        try run("/usr/bin/ditto", ["-x", "-k", leanZip.path, leanOut.path])
        let leanListing = (fm.subpaths(atPath: leanOut.path) ?? [])
            .map { URL(fileURLWithPath: $0).lastPathComponent }
        print("\ntranscripts-only export: \(leanListing.filter { $0.hasSuffix(".m4a") }.count) audio files, "
              + "scores.csv present: \(leanListing.contains("scores.csv"))")

        // 3. A read-only destination must fail cleanly and leave nothing behind.
        let locked = out.appendingPathComponent("locked", isDirectory: true)
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        let blockedZip = locked.appendingPathComponent("nope.zip")
        do {
            try await service.exportPassage(loaded, to: blockedZip, contents: .everything)
            print("\nread-only destination: NO ERROR (unexpected)")
        } catch let f as AppFailure {
            print("\nread-only destination: refused with \"\(f.userMessage)\"")
            print("  partial archive left behind: \(fm.fileExists(atPath: blockedZip.path))")
        }
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)

        // 4. Library export.
        let libZip = out.appendingPathComponent(Paths.libraryExportName(on: Date()))
        try await service.exportLibrary(to: libZip, contents: .everything)
        print("\nlibrary export name: \(libZip.lastPathComponent)")
        print("  exists: \(fm.fileExists(atPath: libZip.path))")
    }

    static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
    }
}
