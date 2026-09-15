import Foundation
import Testing

@Suite("PassageStore")
struct PassageStoreTests {

    /// Every test gets its own temp root, so the suite never touches the real library.
    final class TempRoot {
        let url: URL
        init() {
            url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("oral-english-tests-\(UUID().uuidString)", isDirectory: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }
    }

    func withStore(_ body: (PassageStore, URL) async throws -> Void) async throws {
        let temp = TempRoot()
        let store = PassageStore(root: temp.url)
        try await body(store, temp.url)
        try? FileManager.default.removeItem(at: temp.url)
    }

    static let text = "The fog came in. It sat looking over harbor.\n\nThen it moved on."

    func makeTake(for ref: TargetRef, at rawDate: Date = Date(), accuracy: Double? = nil) -> Take {
        let date = rawDate.wholeSecond
        let id = UUID()
        var score: ScoreReport?
        if let accuracy {
            score = ScoreReport(
                accuracy: accuracy, wordErrorRate: 1 - accuracy, rawWeightedError: 0,
                matchCount: 1, partialCount: 0, substitutionCount: 0, missedCount: 0,
                extraCount: 0, referenceTokenCount: 1, transcript: "x",
                meanConfidence: 0.8, verdict: .clear, engine: "test",
                localeIdentifier: "en-US", scoredAt: date, words: []
            )
        }
        return Take(
            id: id, target: ref, recordedAt: date,
            audioPath: Paths.takeAudioRelativePath(recordedAt: date, id: id),
            durationSeconds: 3.4, referenceText: "The fog came in.", score: score
        )
    }

    // MARK: - Create, load, scan

    @Test("a passage created and reloaded compares equal")
    func createThenLoad() async throws {
        try await withStore { store, _ in
            let created = try await store.create(title: "The fog came in", theme: "Interview prep", text: Self.text)
            let loaded = try await store.load(folderName: created.folderName)
            #expect(loaded.passage == created.passage)
            #expect(loaded.takes.isEmpty)
        }
    }

    @Test("ensureLibrary is idempotent and writes a README")
    func ensureLibraryIdempotent() async throws {
        try await withStore { store, root in
            try await store.ensureLibrary()
            try await store.ensureLibrary()
            let readme = root.appendingPathComponent("README.txt")
            #expect(FileManager.default.fileExists(atPath: readme.path))
            let text = try String(contentsOf: readme, encoding: .utf8)
            #expect(text.contains("recordings of your voice"), "the disclosure must be present")
            #expect(text.contains("iCloud"))
        }
    }

    @Test("three passages produce three summaries with correct titles and counts")
    func scanThree() async throws {
        try await withStore { store, _ in
            for t in ["One", "Two", "Three"] {
                _ = try await store.create(title: t, theme: nil, text: Self.text)
            }
            let summaries = try await store.scanSummaries()
            #expect(summaries.count == 3)
            #expect(Set(summaries.map(\.title)) == ["One", "Two", "Three"])
            for s in summaries {
                #expect(s.sentenceCount == 3)
                #expect(s.takeCount == 0)
                #expect(!s.isBroken)
            }
        }
    }

    /// The difference between one bad file and an unusable library.
    @Test("a corrupt passage.json marks one row broken and leaves the others loading")
    func corruptPassageIsolated() async throws {
        try await withStore { store, root in
            let good = try await store.create(title: "Good", theme: nil, text: Self.text)
            let bad = try await store.create(title: "Bad", theme: nil, text: Self.text)
            let badJSON = Paths.passageJSON(in: root.appendingPathComponent(bad.folderName))
            try Data("{ not json".utf8).write(to: badJSON)

            let summaries = try await store.scanSummaries()
            #expect(summaries.count == 2)
            #expect(summaries.filter(\.isBroken).count == 1)
            let brokenRow = summaries.first { $0.isBroken }
            #expect(brokenRow?.folderName == bad.folderName, "the broken row carries the folder so it can be acted on")
            // The good one still loads.
            let stillGood = try await store.load(folderName: good.folderName)
            #expect(stillGood.passage.title == "Good")
        }
    }

    /// One file per take means a corrupt take costs that take, not the session.
    @Test("a corrupt take file is skipped and the other takes still load")
    func corruptTakeIsolated() async throws {
        try await withStore { store, root in
            let p = try await store.create(title: "T", theme: nil, text: Self.text)
            let ref = TargetRef.sentence(p.passage.sentences[0].id)
            let a = makeTake(for: ref, at: Date().addingTimeInterval(-60))
            let b = makeTake(for: ref, at: Date())
            _ = try await store.appendTake(a, to: p.folderName)
            _ = try await store.appendTake(b, to: p.folderName)

            let takesDir = Paths.takesDirectory(in: root.appendingPathComponent(p.folderName))
            let aJSON = takesDir.appendingPathComponent(
                URL(fileURLWithPath: Paths.takeJSONRelativePath(recordedAt: a.recordedAt, id: a.id)).lastPathComponent)
            try Data("{ broken".utf8).write(to: aJSON)

            let loaded = try await store.load(folderName: p.folderName)
            #expect(loaded.takes.count == 1)
            #expect(loaded.takes[0].id == b.id)
        }
    }

    @Test("no temp file remains after a save")
    func noTempResidue() async throws {
        try await withStore { store, root in
            let p = try await store.create(title: "T", theme: nil, text: Self.text)
            let folder = root.appendingPathComponent(p.folderName)
            let entries = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            #expect(!entries.contains { $0.pathExtension == "tmp" })
        }
    }

    @Test("a stale temp file from a crashed run is cleaned on load")
    func staleTempCleaned() async throws {
        try await withStore { store, root in
            let p = try await store.create(title: "T", theme: nil, text: Self.text)
            let folder = root.appendingPathComponent(p.folderName)
            let stale = folder.appendingPathComponent("passage.json.OLD.tmp")
            try Data("leftover".utf8).write(to: stale)
            _ = try await store.load(folderName: p.folderName)
            #expect(!FileManager.default.fileExists(atPath: stale.path))
        }
    }

    // MARK: - Takes

    @Test("appending a take grows the count and keeps the right target")
    func appendTake() async throws {
        try await withStore { store, _ in
            let p = try await store.create(title: "T", theme: nil, text: Self.text)
            let ref = TargetRef.sentence(p.passage.sentences[1].id)
            let after = try await store.appendTake(makeTake(for: ref), to: p.folderName)
            #expect(after.takes.count == 1)
            #expect(after.takes[0].target == ref)
        }
    }

    /// The test that discriminates between a delta-shaped store and a naive one.
    ///
    /// Revision 1's concurrency test called the actor twice concurrently, which an actor
    /// satisfies trivially. The real lost update is a caller holding a stale copy across an
    /// await and writing it back.
    @Test("appending from a stale cached copy loses neither take")
    func staleCopyAppend() async throws {
        try await withStore { store, _ in
            let p = try await store.create(title: "T", theme: nil, text: Self.text)
            let ref = TargetRef.sentence(p.passage.sentences[0].id)

            // Caller holds this copy across the awaits below.
            let stale = p

            let a = makeTake(for: ref, at: Date().addingTimeInterval(-30))
            _ = try await store.appendTake(a, to: stale.folderName)

            let b = makeTake(for: ref, at: Date())
            let after = try await store.appendTake(b, to: stale.folderName)

            #expect(after.takes.count == 2, "a stale caller copy must not drop the earlier take")
            #expect(Set(after.takes.map(\.id)) == Set([a.id, b.id]))
        }
    }

    @Test("two concurrent appends lose neither")
    func concurrentAppends() async throws {
        try await withStore { store, _ in
            let p = try await store.create(title: "T", theme: nil, text: Self.text)
            let ref = TargetRef.sentence(p.passage.sentences[0].id)
            let a = makeTake(for: ref, at: Date().addingTimeInterval(-10))
            let b = makeTake(for: ref, at: Date())

            await withTaskGroup(of: Void.self) { group in
                group.addTask { _ = try? await store.appendTake(a, to: p.folderName) }
                group.addTask { _ = try? await store.appendTake(b, to: p.folderName) }
            }

            let after = try await store.load(folderName: p.folderName)
            #expect(after.takes.count == 2)
        }
    }

    @Test("scoring one take does not disturb another")
    func scoreIsolation() async throws {
        try await withStore { store, _ in
            let p = try await store.create(title: "T", theme: nil, text: Self.text)
            let ref = TargetRef.sentence(p.passage.sentences[0].id)
            let a = makeTake(for: ref, at: Date().addingTimeInterval(-30))
            let b = makeTake(for: ref, at: Date())
            _ = try await store.appendTake(a, to: p.folderName)
            _ = try await store.appendTake(b, to: p.folderName)

            let score = makeTake(for: ref, accuracy: 0.91).score!
            let after = try await store.updateScore(score, takeID: a.id, in: p.folderName)

            #expect(after.takes.first { $0.id == a.id }?.score?.accuracy == 0.91)
            #expect(after.takes.first { $0.id == b.id }?.score == nil)
        }
    }

    @Test("a take whose audio is absent loads marked unplayable rather than failing the passage")
    func missingAudioMarked() async throws {
        try await withStore { store, _ in
            let p = try await store.create(title: "T", theme: nil, text: Self.text)
            let ref = TargetRef.sentence(p.passage.sentences[0].id)
            let take = makeTake(for: ref)
            let after = try await store.appendTake(take, to: p.folderName)

            #expect(after.takes.count == 1)
            #expect(after.takesMissingAudio.contains(take.id), "no audio was ever written")
            #expect(after.hasAudio(take) == false)
        }
    }

    @Test("importing a recording returns a relative path and the file lands there")
    func importRecording() async throws {
        try await withStore { store, root in
            let p = try await store.create(title: "T", theme: nil, text: Self.text)
            let ref = TargetRef.sentence(p.passage.sentences[0].id)
            let takeID = UUID()
            let when = Date()

            let staged = try await store.stagingURL(in: p.folderName, takeID: takeID)
            try Data("fake audio".utf8).write(to: staged)

            let relative = try await store.importRecording(
                tempURL: staged, into: p.folderName, target: ref, recordedAt: when, takeID: takeID)

            #expect(!relative.hasPrefix("/"), "stored paths are relative")
            #expect(!relative.contains(root.path), "the temp root must not leak into the path")
            let resolved = await store.resolve(relativePath: relative, in: p.folderName)
            #expect(FileManager.default.fileExists(atPath: resolved.path))
        }
    }

    @Test("a take with real audio is not marked missing")
    func presentAudioNotMarked() async throws {
        try await withStore { store, _ in
            let p = try await store.create(title: "T", theme: nil, text: Self.text)
            let ref = TargetRef.sentence(p.passage.sentences[0].id)
            let takeID = UUID()
            let when = Date()
            let staged = try await store.stagingURL(in: p.folderName, takeID: takeID)
            try Data("fake audio".utf8).write(to: staged)
            let relative = try await store.importRecording(
                tempURL: staged, into: p.folderName, target: ref, recordedAt: when, takeID: takeID)
            let take = Take(id: takeID, target: ref, recordedAt: when, audioPath: relative,
                            durationSeconds: 1, referenceText: "x")
            let after = try await store.appendTake(take, to: p.folderName)
            #expect(after.takesMissingAudio.isEmpty)
            #expect(after.hasAudio(take))
        }
    }

    @Test("deleting a take removes both its files")
    func deleteTake() async throws {
        try await withStore { store, _ in
            let p = try await store.create(title: "T", theme: nil, text: Self.text)
            let ref = TargetRef.sentence(p.passage.sentences[0].id)
            let take = makeTake(for: ref)
            _ = try await store.appendTake(take, to: p.folderName)
            let after = try await store.deleteTake(take, in: p.folderName)
            #expect(after.takes.isEmpty)
        }
    }

    // MARK: - Delete and rename

    @Test("deleting a passage removes it from the library")
    func deletePassage() async throws {
        try await withStore { store, root in
            let p = try await store.create(title: "T", theme: nil, text: Self.text)
            try await store.delete(folderName: p.folderName)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(p.folderName).path))
            let summaries = try await store.scanSummaries()
            #expect(summaries.isEmpty)
        }
    }

    @Test("renaming moves the folder and keeps the takes")
    func renameKeepsTakes() async throws {
        try await withStore { store, _ in
            let p = try await store.create(title: "Old title", theme: nil, text: Self.text)
            let ref = TargetRef.sentence(p.passage.sentences[0].id)
            _ = try await store.appendTake(makeTake(for: ref), to: p.folderName)

            let newFolder = try await store.rename(folderName: p.folderName, to: "New title")
            #expect(newFolder != p.folderName)
            let loaded = try await store.load(folderName: newFolder)
            #expect(loaded.passage.title == "New title")
            #expect(loaded.takes.count == 1, "takes must survive a rename")
        }
    }

    @Test("two passages with the same title get distinct folders")
    func sameTitleDistinctFolders() async throws {
        try await withStore { store, _ in
            let a = try await store.create(title: "The fog", theme: nil, text: Self.text)
            let b = try await store.create(title: "The fog", theme: nil, text: Self.text)
            #expect(a.folderName != b.folderName)
            let summaries = try await store.scanSummaries()
            #expect(summaries.count == 2)
        }
    }

    // MARK: - Failure paths

    /// A failed save must surface. Silently losing a take the user just spoke is the one
    /// thing the recorder item treats as a cardinal rule.
    @Test("saving into a read-only directory surfaces an error")
    func readOnlyDirectorySurfaces() async throws {
        try await withStore { store, root in
            let p = try await store.create(title: "T", theme: nil, text: Self.text)
            let folder = root.appendingPathComponent(p.folderName)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }

            let ref = TargetRef.sentence(p.passage.sentences[0].id)
            await #expect(throws: AppFailure.self) {
                _ = try await store.appendTake(makeTake(for: ref), to: p.folderName)
            }
        }
    }

    @Test("loading a passage saved by a newer schema reports itself")
    func schemaTooNewSurfaces() async throws {
        try await withStore { store, root in
            let p = try await store.create(title: "T", theme: nil, text: Self.text)
            var passage = p.passage
            passage.schemaVersion = currentSchemaVersion + 1
            let data = try PassageCoding.encoder().encode(passage)
            try data.write(to: Paths.passageJSON(in: root.appendingPathComponent(p.folderName)))

            await #expect(throws: AppFailure.self) {
                _ = try await store.load(folderName: p.folderName)
            }
        }
    }

    @Test("a corrupt passage is copied aside before it is reported, so it stays hand-fixable")
    func corruptFileQuarantined() async throws {
        try await withStore { store, root in
            let p = try await store.create(title: "T", theme: nil, text: Self.text)
            let folder = root.appendingPathComponent(p.folderName)
            // Valid JSON with the right version but the wrong shape, so the version check
            // passes and the decode fails.
            try Data(#"{"schemaVersion": 1, "unexpected": true}"#.utf8)
                .write(to: Paths.passageJSON(in: folder))

            _ = try? await store.load(folderName: p.folderName)
            let entries = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            #expect(entries.contains { $0.lastPathComponent.contains(".broken-") },
                    "expected a copy aside, got \(entries.map(\.lastPathComponent))")
        }
    }

    @Test("a missing library folder surfaces rather than silently recreating an empty one")
    func missingLibrarySurfaces() async throws {
        let temp = TempRoot()
        // A path under a file, so creation cannot succeed.
        let blocker = temp.url.deletingLastPathComponent()
            .appendingPathComponent("blocker-\(UUID().uuidString)")
        try Data("x".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let store = PassageStore(root: blocker.appendingPathComponent("library", isDirectory: true))
        await #expect(throws: AppFailure.self) {
            try await store.ensureLibrary()
        }
    }

    // MARK: - Incoming recordings

    @Test("an interrupted recording is found on the next launch")
    func pendingIncomingFound() async throws {
        try await withStore { store, _ in
            let p = try await store.create(title: "T", theme: nil, text: Self.text)
            let staged = try await store.stagingURL(in: p.folderName, takeID: UUID())
            try Data("interrupted".utf8).write(to: staged)
            let pending = await store.pendingIncoming(in: p.folderName)
            #expect(pending.count == 1)
        }
    }

    @Test("an unreadable interrupted recording is quarantined, not deleted")
    func quarantineIncoming() async throws {
        try await withStore { store, root in
            let p = try await store.create(title: "T", theme: nil, text: Self.text)
            let staged = try await store.stagingURL(in: p.folderName, takeID: UUID())
            try Data("broken".utf8).write(to: staged)
            try await store.quarantineIncoming(staged, in: p.folderName)

            let recovered = Paths.recoveredDirectory(in: root.appendingPathComponent(p.folderName))
            let entries = try FileManager.default.contentsOfDirectory(at: recovered, includingPropertiesForKeys: nil)
            #expect(entries.count == 1, "an unplayable file the user can see beats a silent delete")
            #expect(await store.pendingIncoming(in: p.folderName).isEmpty)
        }
    }

    // MARK: - Derived data

    @Test("summaries report an average best accuracy once takes are scored")
    func averageBestAccuracy() async throws {
        try await withStore { store, _ in
            let p = try await store.create(title: "T", theme: nil, text: Self.text)
            let ref = TargetRef.sentence(p.passage.sentences[0].id)
            let take = makeTake(for: ref, accuracy: 0.8)
            _ = try await store.appendTake(take, to: p.folderName)
            let summaries = try await store.scanSummaries()
            #expect(summaries.first?.averageBestAccuracy == 0.8)
            #expect(summaries.first?.takeCount == 1)
        }
    }
}
