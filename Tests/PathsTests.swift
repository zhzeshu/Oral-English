import Foundation
import Testing

@Suite("Paths")
struct PathsTests {

    // A fixed instant so every expectation here is deterministic.
    static let sept14 = ISO8601DateFormatter().date(from: "2026-09-14T12:00:00Z")!
    static let fixedID = UUID(uuidString: "A1B2C3D4-0000-4000-8000-000000000001")!

    // MARK: - Golden naming table
    //
    // Committed so that any change to the slug function fails loudly and forces a
    // conscious decision. Without this, editing the slug to suit export names would
    // silently change every future folder name while existing folders kept their old ones,
    // splitting the library in two.

    @Test("golden folder names", arguments: [
        ("The fog came in", "Interview prep", "2026-09-14-interview-prep-the-fog-came-in-a1b2c3d4"),
        ("The fog came in", nil, "2026-09-14-the-fog-came-in-a1b2c3d4"),
        ("Café résumé", nil, "2026-09-14-cafe-resume-a1b2c3d4"),
        ("Hello, World!", nil, "2026-09-14-hello-world-a1b2c3d4"),
        ("  spaced  out  ", nil, "2026-09-14-spaced-out-a1b2c3d4"),
        ("UPPER Case", nil, "2026-09-14-upper-case-a1b2c3d4"),
        ("with 3 numbers 42", nil, "2026-09-14-with-3-numbers-42-a1b2c3d4"),
    ] as [(String, String?, String)])
    func goldenFolderNames(title: String, theme: String?, expected: String) {
        let name = Paths.passageFolderName(
            title: title, theme: theme,
            createdAt: Self.sept14, id: Self.fixedID,
            timeZone: TimeZone(identifier: "UTC")!
        )
        #expect(name == expected)
    }

    @Test("golden export names", arguments: [
        ("The fog came in", "Interview prep", "OralEnglish-2026-09-14-interview-prep-the-fog-came-in.zip"),
        ("The fog came in", nil, "OralEnglish-2026-09-14-the-fog-came-in.zip"),
    ] as [(String, String?, String)])
    func goldenExportNames(title: String, theme: String?, expected: String) {
        let name = Paths.passageExportName(
            title: title, theme: theme,
            createdAt: Self.sept14,
            timeZone: TimeZone(identifier: "UTC")!
        )
        #expect(name == expected)
    }

    // MARK: - Slugs that used to break

    /// Every one of these slugged to the empty string under revision 1's rule, producing
    /// exactly the double hyphen that rule forbade.
    @Test("a title with no ASCII letters never slugs to empty", arguments: [
        "???", "…", "🎉🎉🎉", "-", "!!!", "...", "   ", "",
    ])
    func neverEmptySlug(title: String) {
        let s = Paths.slug(title)
        #expect(!s.isEmpty)
        #expect(!s.contains("--"))
        let name = Paths.passageFolderName(
            title: title, theme: "Interview prep",
            createdAt: Self.sept14, id: Self.fixedID
        )
        #expect(!name.contains("--"), "got \(name)")
        #expect(Paths.isSafeComponent(name), "got \(name)")
    }

    @Test("a CJK title transliterates rather than vanishing")
    func cjkTransliterates() {
        let s = Paths.slug("中文标题")
        #expect(!s.isEmpty)
        #expect(s != Paths.untitledSlug, "expected a transliteration, got the fallback")
        #expect(!s.contains("--"))
    }

    @Test("path traversal cannot survive the slug", arguments: [
        "../../evil", "..", ".", "a/b/c", "/etc/passwd", "..\\..\\windows",
    ])
    func noTraversal(title: String) {
        let s = Paths.slug(title)
        #expect(!s.contains("/"))
        #expect(!s.contains(".."))
        #expect(s != "." && s != "..")
        #expect(Paths.isSafeComponent(s))
    }

    @Test("leading dots and hyphens are removed", arguments: [
        (".hidden", "hidden"), ("-rf", "rf"), ("--force", "force"), ("...leading", "leading"),
    ])
    func noLeadingSpecials(title: String, expected: String) {
        #expect(Paths.slug(title) == expected)
    }

    @Test("a very long title is capped and does not end on a hyphen")
    func longTitleCapped() {
        let title = String(repeating: "word ", count: 200)
        let name = Paths.passageFolderName(
            title: title, theme: "A theme",
            createdAt: Self.sept14, id: Self.fixedID
        )
        #expect(name.utf8.count <= Paths.maxComponentLength, "length \(name.utf8.count)")
        #expect(!name.hasSuffix("-"))
        #expect(!name.contains("--"))
        #expect(Paths.isSafeComponent(name))
    }

    @Test("a 500-character single-word title still produces a usable component")
    func veryLongSingleWord() {
        let name = Paths.passageFolderName(
            title: String(repeating: "x", count: 500), theme: nil,
            createdAt: Self.sept14, id: Self.fixedID
        )
        #expect(name.utf8.count <= Paths.maxComponentLength)
        #expect(Paths.isSafeComponent(name))
    }

    @Test("two titles that slug alike still get distinct folders")
    func distinctIDs() {
        let a = Paths.passageFolderName(title: "The Fog", theme: nil, createdAt: Self.sept14, id: UUID())
        let b = Paths.passageFolderName(title: "the fog", theme: nil, createdAt: Self.sept14, id: UUID())
        #expect(a != b)
    }

    /// The filesystem is case-insensitive APFS, verified. Since the slug is already
    /// lowercased, the short id is the only differentiator — so it must be lowercase, or two
    /// passages could name the same directory and a create would silently merge them.
    @Test("short ids are lowercase, so two cannot differ only in case")
    func shortIDIsLowercase() {
        for _ in 0..<200 {
            let s = Paths.shortID(from: UUID())
            #expect(s == s.lowercased())
            #expect(s.count == 8)
            #expect(s.allSatisfy { $0.isHexDigit })
        }
    }

    // MARK: - Take filenames

    @Test("a take filename carries no colon")
    func noColonInTakeName() {
        let p = Paths.takeAudioRelativePath(recordedAt: Self.sept14, id: Self.fixedID)
        #expect(!p.contains(":"))
        #expect(p.hasPrefix("takes/"))
        #expect(p.hasSuffix(".m4a"))
    }

    @Test("audio and JSON for one take share a stem, so a missing pair is obvious")
    func audioAndJSONShareStem() {
        let a = Paths.takeAudioRelativePath(recordedAt: Self.sept14, id: Self.fixedID)
        let j = Paths.takeJSONRelativePath(recordedAt: Self.sept14, id: Self.fixedID)
        #expect(a.replacingOccurrences(of: ".m4a", with: "") == j.replacingOccurrences(of: ".json", with: ""))
    }

    /// Two takes in the same second must not collide: one would overwrite the other's audio.
    @Test("two takes in the same second get distinct filenames")
    func sameSecondNoCollision() {
        let a = Paths.takeAudioRelativePath(recordedAt: Self.sept14, id: UUID())
        let b = Paths.takeAudioRelativePath(recordedAt: Self.sept14, id: UUID())
        #expect(a != b)
    }

    @Test("stored paths are relative, never absolute")
    func pathsAreRelative() {
        let a = Paths.takeAudioRelativePath(recordedAt: Self.sept14, id: Self.fixedID)
        let r = Paths.referenceAudioRelativePath(for: .sentence(Self.fixedID))
        #expect(!a.hasPrefix("/"))
        #expect(!r.hasPrefix("/"))
    }

    // MARK: - Time zones

    /// The date leads every folder name, so a passage created late in the evening must not
    /// land on a different day than its own `createdAt` string.
    @Test("the naming date respects the given time zone")
    func timeZoneBoundary() {
        // 23:30 on 14 Sep in New York is 03:30 on 15 Sep UTC.
        let late = ISO8601DateFormatter().date(from: "2026-09-15T03:30:00Z")!
        let ny = Paths.nameDateFormatter(timeZone: TimeZone(identifier: "America/New_York")!).string(from: late)
        let utc = Paths.nameDateFormatter(timeZone: TimeZone(identifier: "UTC")!).string(from: late)
        #expect(ny == "2026-09-14")
        #expect(utc == "2026-09-15")
        #expect(ny != utc, "this is the boundary the test exists to pin")
    }

    // MARK: - Export names

    @Test("two library exports on the same day do not collide")
    func libraryExportsDistinct() {
        let a = Paths.libraryExportName(on: Self.sept14)
        let b = Paths.libraryExportName(on: Self.sept14)
        #expect(a != b)
        #expect(a.hasSuffix(".zip"))
        #expect(a.contains("2026-09-14"))
    }

    @Test("a shell-hostile title produces a safe single component", arguments: [
        "back`tick", "dollar$(whoami)", "semi;colon", "new\nline", "pipe|it", "and&&more",
    ])
    func shellHostileTitles(title: String) {
        let name = Paths.passageExportName(title: title, theme: nil, createdAt: Self.sept14)
        #expect(!name.contains("/"))
        #expect(!name.contains("\n"))
        #expect(!name.contains("`"))
        #expect(!name.contains("$"))
        #expect(!name.contains(";"))
        #expect(!name.contains("|"))
        #expect(name.hasSuffix(".zip"))
    }

    @Test("an export name with a long prefix and theme stays within the limit")
    func exportNameClamped() {
        let name = Paths.passageExportName(
            title: String(repeating: "title ", count: 100),
            theme: String(repeating: "theme ", count: 20),
            createdAt: Self.sept14
        )
        #expect(name.utf8.count <= Paths.maxComponentLength, "length \(name.utf8.count)")
    }

    // MARK: - Component safety

    @Test("isSafeComponent rejects what it should", arguments: [
        ("", false), (".", false), ("..", false), (".hidden", false), ("-lead", false),
        ("trail-", false), ("dou--ble", false), ("a/b", false), ("a:b", false),
        ("2026-09-14-ok-a1b2c3d4", true), ("untitled", true),
    ] as [(String, Bool)])
    func componentSafety(input: String, expected: Bool) {
        #expect(Paths.isSafeComponent(input) == expected)
    }

    @Test("a component containing a control character is rejected")
    func rejectsControlCharacters() {
        #expect(!Paths.isSafeComponent("a\0b"))
        #expect(!Paths.isSafeComponent("a\u{07}b"))
    }
}
