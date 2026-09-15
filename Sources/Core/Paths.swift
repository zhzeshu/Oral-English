import Foundation

/// Pure path and naming math. No I/O beyond `FileManager` queries.
public enum Paths {

    /// Maximum bytes for one path component. APFS caps at 255; verified that 256 fails.
    public static let maxComponentLength = 255
    /// Budget for the title slug, leaving room for the date prefix, theme and id suffix.
    public static let maxTitleSlugLength = 120
    public static let untitledSlug = "untitled"

    // MARK: - Library location

    public static func defaultLibraryRoot() -> URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Oral English", isDirectory: true)
    }

    /// Never-synced alternative, offered when the Documents folder turns out to be an
    /// iCloud ubiquitous container. Under sync, audio is evicted to dataless placeholders
    /// and `replaceItemAt` generates conflict duplicates.
    public static func applicationSupportLibraryRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Oral English", isDirectory: true)
    }

    // MARK: - Slugs

    /// A positive whitelist, not a description of the output.
    ///
    /// Revision 1 specified "lowercase ASCII, hyphen-separated, no double hyphens" as a
    /// property of the result, which is why it never caught the case that violates it: a
    /// title with no ASCII letters at all slugs to the empty string and produces exactly
    /// the double hyphen the rule forbade. Measured on `"???"`, `"中文标题"`, `"…"` and
    /// `"🎉🎉🎉"`.
    public static func slug(_ raw: String, fallback: String = untitledSlug, maxLength: Int = maxTitleSlugLength) -> String {
        var working = raw.precomposedStringWithCanonicalMapping

        // Transliterate before giving up, so a CJK title stays identifiable in Finder
        // rather than becoming "untitled".
        if !TextIntake.hasLatinLetters(working) {
            if let latin = working.applyingTransform(.toLatin, reverse: false) {
                working = latin
            }
        }

        // Fold diacritics to ASCII.
        let folded = working.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))

        // Keep only [a-z0-9]; every other run becomes a single hyphen.
        var out = ""
        var pendingHyphen = false
        for scalar in folded.unicodeScalars {
            let isDigit = scalar.value >= 0x30 && scalar.value <= 0x39
            let isLower = scalar.value >= 0x61 && scalar.value <= 0x7A
            let isUpper = scalar.value >= 0x41 && scalar.value <= 0x5A
            if isDigit || isLower {
                if pendingHyphen && !out.isEmpty { out.append("-") }
                pendingHyphen = false
                out.unicodeScalars.append(scalar)
            } else if isUpper {
                if pendingHyphen && !out.isEmpty { out.append("-") }
                pendingHyphen = false
                out.append(Character(scalar).lowercased())
            } else {
                pendingHyphen = true
            }
        }

        out = truncateOnHyphenBoundary(out, maxLength: maxLength)
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return out.isEmpty ? fallback : out
    }

    /// Truncates without leaving a trailing hyphen or splitting a word when avoidable.
    static func truncateOnHyphenBoundary(_ s: String, maxLength: Int) -> String {
        guard s.count > maxLength else { return s }
        let cut = String(s.prefix(maxLength))
        if let lastHyphen = cut.lastIndex(of: "-"), cut.distance(from: cut.startIndex, to: lastHyphen) > maxLength / 3 {
            return String(cut[cut.startIndex..<lastHyphen])
        }
        return cut.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    // MARK: - Dates

    /// One calendar for every date in a name, so a folder name and its own `createdAt`
    /// cannot disagree. A passage created at 23:30 local time would otherwise land on a
    /// different day under UTC.
    public static func nameDateFormatter(timeZone: TimeZone = .current) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    /// Timestamp for a take filename. No colons: APFS allows them but Finder renders a
    /// colon as a slash.
    public static func takeTimestampFormatter(timeZone: TimeZone = TimeZone(identifier: "UTC")!) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd'T'HHmmss'Z'"
        return f
    }

    // MARK: - Folder and file names

    /// Lowercase hex, so two ids cannot differ only in case.
    ///
    /// The filesystem is case-insensitive APFS, verified. Since the slug is already
    /// lowercased, the id is the only differentiator between two same-titled passages — a
    /// mixed-case alphabet would let them name the same directory, and `mkdir -p` would
    /// merge them silently.
    public static func shortID(from uuid: UUID) -> String {
        uuid.uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8).description
    }

    /// `2026-09-14-interview-prep-the-fog-came-in-a1b2c3d4`
    ///
    /// The date leads so a Finder sort by name is also chronological.
    public static func passageFolderName(
        title: String,
        theme: String?,
        createdAt: Date,
        id: UUID,
        timeZone: TimeZone = .current
    ) -> String {
        let date = nameDateFormatter(timeZone: timeZone).string(from: createdAt)
        let themeSlug = theme.flatMap { t -> String? in
            let s = slug(t, fallback: "", maxLength: 40)
            return s.isEmpty ? nil : s
        }
        let titleSlug = slug(title)
        let short = shortID(from: id)

        var parts = [date]
        if let themeSlug { parts.append(themeSlug) }
        parts.append(titleSlug)
        parts.append(short)

        var name = parts.joined(separator: "-")
        // Collapse any accidental doubling and clamp to the filesystem limit.
        while name.contains("--") { name = name.replacingOccurrences(of: "--", with: "-") }
        if name.utf8.count > maxComponentLength {
            let keep = maxComponentLength - date.count - short.count - 2
            let shortened = truncateOnHyphenBoundary(titleSlug, maxLength: max(keep, 8))
            name = ([date] + (themeSlug.map { [$0] } ?? []) + [shortened, short]).joined(separator: "-")
            while name.contains("--") { name = name.replacingOccurrences(of: "--", with: "-") }
        }
        return name.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    public static func passageJSON(in folder: URL) -> URL {
        folder.appendingPathComponent("passage.json", isDirectory: false)
    }

    public static func takesDirectory(in folder: URL) -> URL {
        folder.appendingPathComponent("takes", isDirectory: true)
    }

    public static func incomingDirectory(in folder: URL) -> URL {
        folder.appendingPathComponent("incoming", isDirectory: true)
    }

    public static func recoveredDirectory(in folder: URL) -> URL {
        folder.appendingPathComponent("recovered", isDirectory: true)
    }

    public static func referenceDirectory(in folder: URL) -> URL {
        folder.appendingPathComponent("reference", isDirectory: true)
    }

    /// `2026-09-14T201733Z-7f3a12`. The audio and its JSON share this stem, so they sort
    /// together and a missing pair is obvious in Finder.
    public static func takeStem(recordedAt: Date, id: UUID) -> String {
        let ts = takeTimestampFormatter().string(from: recordedAt)
        let short = shortID(from: id).prefix(6)
        return "\(ts)-\(short)"
    }

    /// Relative to the passage folder, always.
    public static func takeAudioRelativePath(recordedAt: Date, id: UUID) -> String {
        "takes/\(takeStem(recordedAt: recordedAt, id: id)).m4a"
    }

    public static func takeJSONRelativePath(recordedAt: Date, id: UUID) -> String {
        "takes/\(takeStem(recordedAt: recordedAt, id: id)).json"
    }

    public static func referenceAudioRelativePath(for ref: TargetRef) -> String {
        "reference/\(ref.kind.rawValue)-\(ref.id.uuidString.lowercased()).m4a"
    }

    // MARK: - Export names

    /// `OralEnglish-2026-09-14-interview-prep-the-fog-came-in.zip`
    public static func passageExportName(
        title: String,
        theme: String?,
        createdAt: Date,
        timeZone: TimeZone = .current
    ) -> String {
        let date = nameDateFormatter(timeZone: timeZone).string(from: createdAt)
        let themeSlug = theme.flatMap { t -> String? in
            let s = slug(t, fallback: "", maxLength: 40)
            return s.isEmpty ? nil : s
        }
        var parts = ["OralEnglish", date]
        if let themeSlug { parts.append(themeSlug) }
        parts.append(slug(title))
        var name = parts.joined(separator: "-")
        while name.contains("--") { name = name.replacingOccurrences(of: "--", with: "-") }
        name = clampName(name, reservedSuffix: ".zip")
        return name + ".zip"
    }

    /// `OralEnglish-Library-2026-09-14-a1b2c3d4.zip`
    ///
    /// The short id is what stops two exports on the same day colliding. Revision 1's
    /// library name carried only the date.
    public static func libraryExportName(
        on date: Date,
        disambiguator: UUID = UUID(),
        timeZone: TimeZone = .current
    ) -> String {
        let d = nameDateFormatter(timeZone: timeZone).string(from: date)
        return "OralEnglish-Library-\(d)-\(shortID(from: disambiguator)).zip"
    }

    static func clampName(_ name: String, reservedSuffix: String) -> String {
        let budget = maxComponentLength - reservedSuffix.utf8.count
        guard name.utf8.count > budget else { return name }
        return truncateOnHyphenBoundary(name, maxLength: budget)
    }

    // MARK: - Validation

    /// A generated component must be one path component with nothing surprising in it.
    public static func isSafeComponent(_ s: String) -> Bool {
        if s.isEmpty { return false }
        if s.contains("/") || s.contains(":") { return false }
        if s.hasPrefix(".") || s.hasPrefix("-") { return false }
        if s.contains("--") { return false }
        if s.hasSuffix("-") { return false }
        if s == "." || s == ".." { return false }
        if s.utf8.count > maxComponentLength { return false }
        if s.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { return false }
        return true
    }
}
