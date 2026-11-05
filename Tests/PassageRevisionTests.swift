import Foundation
import Testing

@Suite("PassageRevision")
struct PassageRevisionTests {

    static let t0 = ISO8601DateFormatter().date(from: "2026-11-04T09:00:00Z")!

    static func passage(_ text: String) -> Passage {
        let r = SentenceSplitter.split(text)
        return Passage(
            title: "T", createdAt: t0, updatedAt: t0,
            sourceText: TextIntake.clean(text),
            paragraphs: r.paragraphs, sentences: r.sentences
        )
    }

    static let base = "The fog came in. It sat looking over the harbor.\n\nThen it moved on. The city was quiet."

    func ids(_ p: Passage) -> [UUID] { p.sentences.map(\.id) }
    func ids(_ r: PassageRevision) -> [UUID] { r.sentences.map(\.id) }

    // MARK: - Sentences

    @Test("unchanged text keeps every sentence and paragraph id, and reports no change")
    func unchangedKeepsEverything() {
        let old = Self.passage(Self.base)
        let r = PassageRevision(from: old, to: Self.base)
        #expect(ids(r) == ids(old))
        #expect(r.paragraphs.map(\.id) == old.paragraphs.map(\.id))
        #expect(r.editedSentenceIDs.isEmpty)
        #expect(r.addedSentenceIDs.isEmpty)
        #expect(r.removedSentenceIDs.isEmpty)
        #expect(!r.hasChanges)
    }

    @Test("fixing one word keeps that sentence's id and marks it edited")
    func editKeepsID() {
        let old = Self.passage(Self.base)
        let r = PassageRevision(from: old, to: Self.base.replacingOccurrences(of: "fog came", with: "fog rolled"))
        #expect(ids(r) == ids(old))
        #expect(r.sentences[0].text == "The fog rolled in.")
        #expect(r.editedSentenceIDs == [old.sentences[0].id])
        #expect(r.addedSentenceIDs.isEmpty)
        #expect(r.removedSentenceIDs.isEmpty)
        #expect(r.hasChanges)
    }

    @Test("inserting a sentence keeps the others and adds one fresh id")
    func insertion() {
        let old = Self.passage(Self.base)
        let text = Self.base.replacingOccurrences(of: "The fog came in. ", with: "The fog came in. Nobody saw it. ")
        let r = PassageRevision(from: old, to: text)
        #expect(r.sentences.count == 5)
        #expect(r.sentences[1].text == "Nobody saw it.")
        #expect(ids(r).filter { ids(old).contains($0) } == ids(old))
        #expect(r.addedSentenceIDs == [r.sentences[1].id])
        #expect(!ids(old).contains(r.sentences[1].id))
        #expect(r.editedSentenceIDs.isEmpty)
    }

    @Test("deleting a sentence reports it removed and keeps the rest")
    func deletion() {
        let old = Self.passage(Self.base)
        let r = PassageRevision(from: old, to: Self.base.replacingOccurrences(of: " It sat looking over the harbor.", with: ""))
        #expect(ids(r) == [old.sentences[0].id, old.sentences[2].id, old.sentences[3].id])
        #expect(r.removedSentenceIDs == [old.sentences[1].id])
        #expect(r.addedSentenceIDs.isEmpty)
    }

    @Test("a sentence moved elsewhere keeps its id")
    func moveKeepsID() {
        let old = Self.passage(Self.base)
        let moved = "It sat looking over the harbor. The fog came in.\n\nThen it moved on. The city was quiet."
        let r = PassageRevision(from: old, to: moved)
        #expect(Set(ids(r)) == Set(ids(old)))
        #expect(r.sentences[0].id == old.sentences[1].id)
        #expect(r.sentences[1].id == old.sentences[0].id)
        #expect(r.addedSentenceIDs.isEmpty)
        #expect(r.removedSentenceIDs.isEmpty)
    }

    @Test("a completely rewritten sentence is a removal plus an addition, not an edit")
    func rewriteIsNotAnEdit() {
        let old = Self.passage(Self.base)
        let r = PassageRevision(from: old, to: Self.base.replacingOccurrences(of: "The city was quiet.", with: "Birds began singing everywhere."))
        #expect(r.removedSentenceIDs == [old.sentences[3].id])
        #expect(r.addedSentenceIDs == [r.sentences[3].id])
        #expect(r.editedSentenceIDs.isEmpty)
    }

    @Test("splitting a sentence keeps the id on the first half")
    func splitKeepsFirstHalf() {
        let old = Self.passage("The fog came in on little cat feet over the harbor and city.")
        let r = PassageRevision(from: old, to: "The fog came in on little cat feet. It sat over the harbor and city.")
        #expect(r.sentences.count == 2)
        #expect(r.sentences[0].id == old.sentences[0].id)
        #expect(r.editedSentenceIDs == [old.sentences[0].id])
        #expect(r.addedSentenceIDs == [r.sentences[1].id])
    }

    @Test("duplicate sentences never share an id")
    func duplicates() {
        let old = Self.passage("Yes. No. Yes.")
        let r = PassageRevision(from: old, to: "No. Yes. Yes. Yes.")
        #expect(Set(ids(r)).count == r.sentences.count)
        #expect(Set(ids(old)).isSubset(of: Set(ids(r))))
        #expect(r.addedSentenceIDs.count == 1)
        #expect(r.removedSentenceIDs.isEmpty)
    }

    @Test("indices are renumbered in reading order and paragraphs point at the new ids")
    func indicesAndLinks() {
        let old = Self.passage(Self.base)
        let r = PassageRevision(from: old, to: "Opening line.\n\n" + Self.base)
        #expect(r.sentences.map(\.index) == Array(0..<r.sentences.count))
        #expect(r.sentences.map(\.paragraphIndex) == [0, 1, 1, 2, 2])
        #expect(r.paragraphs.map(\.index) == [0, 1, 2])
        #expect(r.paragraphs.flatMap(\.sentenceIDs) == ids(r))
    }

    // MARK: - Paragraphs

    @Test("a paragraph keeps its id when one of its sentences is edited")
    func paragraphSurvivesEdit() {
        let old = Self.passage(Self.base)
        let r = PassageRevision(from: old, to: Self.base.replacingOccurrences(of: "moved on", with: "drifted on"))
        #expect(r.paragraphs.map(\.id) == old.paragraphs.map(\.id))
        #expect(r.removedParagraphIDs.isEmpty)
    }

    @Test("a new paragraph gets a fresh id")
    func newParagraph() {
        let old = Self.passage(Self.base)
        let r = PassageRevision(from: old, to: Self.base + "\n\nA brand new ending.")
        #expect(r.paragraphs.count == 3)
        #expect(Array(r.paragraphs.prefix(2).map(\.id)) == old.paragraphs.map(\.id))
        #expect(!old.paragraphs.map(\.id).contains(r.paragraphs[2].id))
    }

    @Test("merging two paragraphs keeps the first id and removes the second")
    func mergedParagraphs() {
        let old = Self.passage(Self.base)
        let r = PassageRevision(from: old, to: Self.base.replacingOccurrences(of: "\n\n", with: " "))
        #expect(r.paragraphs.count == 1)
        #expect(r.paragraphs[0].id == old.paragraphs[0].id)
        #expect(r.removedParagraphIDs == [old.paragraphs[1].id])
        #expect(ids(r) == ids(old), "sentences survive the merge")
    }

    // MARK: - Applying and orphans

    @Test("applying replaces text and structure, keeps identity, and stamps the date")
    func applied() {
        let old = Self.passage(Self.base)
        let later = Self.t0.addingTimeInterval(3600)
        let text = "**The fog** came in.\r\n\r\nIt left."
        let p = PassageRevision(from: old, to: text).applied(to: old, at: later)
        #expect(p.id == old.id)
        #expect(p.title == old.title)
        #expect(p.createdAt == old.createdAt)
        #expect(p.updatedAt == later)
        #expect(p.sourceText == TextIntake.clean(text))
        #expect(p.sentences.map(\.text) == ["The fog came in.", "It left."])
        #expect(p.sentences[0].id == old.sentences[0].id)
        #expect(p.sentences[0].styles == [InlineStyle(kind: .strong, location: 0, length: 7)])
    }

    @Test("orphaned takes are those on removed sentences and paragraphs, never the whole passage")
    func orphans() {
        let old = Self.passage(Self.base)
        func take(_ ref: TargetRef) -> Take {
            Take(target: ref, recordedAt: Self.t0, audioPath: "a", durationSeconds: 1, referenceText: "x")
        }
        let onRemoved = take(.sentence(old.sentences[3].id))
        let onEdited = take(.sentence(old.sentences[2].id))
        let onRemovedParagraph = take(.paragraph(old.paragraphs[1].id))
        let onPassage = take(.passage(old.id))
        // Second paragraph collapses to one rewritten sentence that matches neither.
        let text = "The fog came in. It sat looking over the harbor.\n\nThen it moved on swiftly."
        let r = PassageRevision(from: old, to: text)
        let orphaned = r.orphanedTakes([onRemoved, onEdited, onRemovedParagraph, onPassage])
        #expect(Set(orphaned.map(\.id)) == [onRemoved.id])
        #expect(r.paragraphs[1].id == old.paragraphs[1].id, "the paragraph kept its id via the edited sentence")

        let merged = PassageRevision(from: old, to: Self.base.replacingOccurrences(of: "\n\n", with: " "))
        #expect(merged.orphanedTakes([onRemovedParagraph, onPassage]).map(\.id) == [onRemovedParagraph.id])
    }
}
