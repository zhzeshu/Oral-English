import Foundation

// Exercises the store against a temporary library, so the on-disk layout can be inspected
// without driving the UI. Not a test: the suite covers behavior. This shows the shape.

@main
struct StoreProbe {
    static func main() async throws {
        // With a path argument, seed that library and leave it in place. Without one, use
        // a throwaway directory and clean up.
        let seedPath = CommandLine.arguments.dropFirst().first
        let keep = seedPath != nil
        let root = seedPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("oral-english-probe-\(UUID().uuidString)", isDirectory: true)

        let text = """
        The fog came in on little cat feet. It sat looking over harbor and city.

        Then, at 4 p.m., it moved on.
        """

        let store = PassageStore(root: root)

        let created = try await store.create(title: "The fog came in", theme: "Interview prep", text: text)
        print("folder: \(created.folderName)")
        print("sentences: \(created.passage.sentences.count), paragraphs: \(created.passage.paragraphs.count)")
        for s in created.passage.sentences {
            print("  [\(s.index)] p\(s.paragraphIndex): \(s.text)")
        }

        // Append two takes to show that appending writes small files and rewrites nothing.
        let ref = TargetRef.sentence(created.passage.sentences[0].id)
        for i in 0..<2 {
            let id = UUID()
            let when = Date().addingTimeInterval(Double(i) * 60).wholeSecond
            let staged = try await store.stagingURL(in: created.folderName, takeID: id)
            try Data("fake audio \(i)".utf8).write(to: staged)
            let rel = try await store.importRecording(
                tempURL: staged, into: created.folderName, target: ref, recordedAt: when, takeID: id)
            let take = Take(id: id, target: ref, recordedAt: when, audioPath: rel,
                            durationSeconds: 3.4, referenceText: created.passage.sentences[0].text)
            _ = try await store.appendTake(take, to: created.folderName)
        }

        let loaded = try await store.load(folderName: created.folderName)
        print("takes: \(loaded.takes.count), missing audio: \(loaded.takesMissingAudio.count)")

        print("\non-disk layout:")
        let fm = FileManager.default
        // enumerator's iterator is unavailable from an async context, so collect first.
        let all: [URL] = {
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return [] }
            return walker.compactMap { $0 as? URL }
        }()
        for url in all.sorted(by: { $0.path < $1.path }) {
            let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            print("  \(rel)\(isDir ? "/" : "  (\(size) bytes)")")
        }

        print("\npassage.json as stored:")
        let folder = await store.folderURL(created.folderName)
        let json = try String(contentsOf: Paths.passageJSON(in: folder), encoding: .utf8)
        print(json.split(separator: "\n").prefix(14).joined(separator: "\n"))

        if keep {
            print("\n(library left in place at \(root.path))")
        } else {
            try? fm.removeItem(at: root)
            print("\n(temp library removed)")
        }

    }
}
