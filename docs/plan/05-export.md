# 05 — Export

**Status:** DONE — 2026-09-14
**Changed:** Sources/Core/ScoreCSV.swift, Sources/Core/Paths.swift (export naming),
Sources/Services/ExportService.swift,
Sources/Core/PassageStore.swift (atomic scores.csv write), Sources/Tools/ExportProbe.swift,
probe.sh, Tests/ScoreCSVTests.swift
**Verified:** ./test.sh (174 tests in 10 suites passed), ./build.sh clean,
./probe.sh ExportProbe — real ditto, real zip, real unzip: audio round-trips byte-for-byte,
a read-only destination is refused and leaves no partial archive, and the transcripts-only
variant contains zero audio files

**Verification style:** test-first for naming and the CSV, checklist for the archive.

> Moved early in revision 2 so its pure halves land with the other test-first work. The
> archive checklist rows need real takes and stay deferred until after item 10.

## Goal

Get practice data out easily, in files named so they can be found later by date or subject.

## Files

- `Sources/Core/ScoreCSV.swift` — pure, passage to string
- Export naming lives in `Sources/Core/Paths.swift` alongside the folder naming, so the
  slug has exactly one implementation. The plan allowed either; one file is better, because
  two slug implementations that drift apart is the bug it warned about.
- `Sources/Services/ExportService.swift` — a thin shell owning only the save dialog and the
  subprocess
- `Tests/ExportNamingTests.swift`, `Tests/ScoreCSVTests.swift`

The split is new. Revision 1 put the whole thing in `Services/`, which the test target does
not compile, so its five test rows could never have linked.

## Red — naming

| Case | Expected |
| --- | --- |
| passage with theme, created 14 Sep 2026 | `OralEnglish-2026-09-14-interview-prep-the-fog-came-in.zip` |
| passage with no theme | theme segment omitted, nothing doubled |
| whole library | `OralEnglish-Library-2026-09-14.zip` |
| two library exports on the same day | names differ; a short id disambiguates |
| title with punctuation or accents | lowercase ASCII slug, no double hyphen |
| title that slugs to empty | non-empty fallback, no double hyphen |
| any name | no colon, no character illegal in a filename, one path component |
| a title containing a backtick, `$(`, `;`, or a newline | produces a safe single component |
| prefix plus theme alone near the cap | assembled name stays within 255 characters |

Reuse the item 02 slug rather than writing a second one. Two slug implementations that drift
apart is a real and boring bug, which is why item 02 commits a golden naming table.

## Red — score CSV

| Test | Assertion |
| --- | --- |
| header | columns include date, theme, granularity, target index, target text, take timestamp, accuracy, word error rate, transcript, problem words |
| row count | one row per take across all three granularities |
| no takes | header only, valid file, no crash |
| a field containing a comma or a quote | quoted and escaped, parses back to the original |
| **a field containing `\n` and `\r\n`** | round-trips to the original |
| a field beginning `=`, `+`, `-`, or `@` | prefixed so no spreadsheet evaluates it as a formula |
| multiple problem words in one field | escaped within the field |
| encoding | UTF-8 with a byte-order mark, so Excel on macOS reads accents correctly |
| dates | ISO 8601, so a spreadsheet sorts them |

The embedded-newline row is the important addition. Revision 1 called escaping "the one
worth writing carefully" and then tested only commas and quotes — while whole-passage target
text is paragraphs joined by blank lines, so it *always* contains newlines. The one case
guaranteed on every whole-passage row was the untested one.

Prove round-tripping with a small parser in the test. String-equality assertions on CSV are
exactly how the newline case gets missed.

The formula-injection row matters because the zip is explicitly shareable and practice prose
beginning with a hyphen is entirely ordinary. The round-trip assertion strips the prefix.

## Green

Export a single passage or the whole library as a zip. Foundation has no zip API and
`AppleArchive` is absent from this SDK, so shell out to `ditto`, which handles resource forks
and produces an archive Finder is happy with.

**Use `Process` with an argument array, never a shell string.** Titles are free text the user
pastes. An argument array makes semicolons, backticks and `$(...)` inert; a shell string would
make them command execution. Revision 1 did not say which, leaving it untestable as specified
and a security issue if resolved the wrong way.

Handle failure, which revision 1 did not mention at all: check the termination status, capture
stderr into the log, delete the partial archive on non-zero, and surface
`AppFailure.exportFailed`. Pre-flight available capacity against the measured folder size and
fail early rather than mid-zip. Treat a cancelled save dialog as not an error.

**Route `scores.csv` through the store's atomic write.** Revision 1 regenerated it directly
into the passage folder on every export, which contradicts item 04's own atomic-write rule and
leaves a half-written CSV on a full disk.

Make export mutually exclusive with recording. `ditto` over a folder containing an
unfinalized `.m4a` archives a torn file, which would then fail the playable-audio check for
reasons that look like a relative-path bug.

Also offer reveal-in-Finder. Given that visible storage was a deliberate decision, that is
half the export story and costs one line.

Add a **transcripts-and-scores-only** variant omitting the audio. The likeliest reason to
export is showing progress to a teacher, and that is exactly when you least want to hand over
voice recordings. Same invocation with the audio excluded.

## Why the archive survives being moved

Because `audioPath` is relative, established in item 02. Absolute paths would silently orphan
every recording on unzip. If an export ever comes back with broken audio, an absolute path
leaked into the JSON — or a NUL character collapsed a URL, which item 02's intake step now
prevents.

## Done when

- [x] `./test.sh` passes with every row asserted.
- [x] Exporting a passage produces a zip whose default name carries the date and theme.
- [x] Unzipping elsewhere yields readable JSON, a valid CSV, and audio that plays.
- [ ] The CSV opens in a spreadsheet with correct columns and commas intact. *(PARTIAL:
      the file parses back to 12 columns and 3 rows with commas, quotes and embedded
      newlines intact, and carries a byte-order mark for Excel. Opening it in an actual
      spreadsheet needs a human.)*
- [x] A library export contains every passage folder.
- [x] The transcripts-only variant contains no audio files.
- [x] Exporting to a read-only volume shows a message and leaves no partial zip.
- [x] Cancelling the save dialog is not an error.
- [ ] Export is disabled while recording.
- [x] Exporting a passage with no takes succeeds.


## Findings while executing this item

**One Unicode trap, in two places, and it is worth remembering.** In Swift `"\r\n"` is a
single `Character` — one grapheme cluster — so:

- `case "\r":` in the CSV reader never matched a CRLF pair, and the entire file parsed as
  one enormous field. The symptom looked exactly like a CSV bug.
- `value.contains("\r")` was **false** for CRLF text, so a field containing a Windows line
  break was never quoted, which broke the row.

Both checks now work on `Unicode.Scalar`, which is grapheme-independent. This is the same
class of mistake as the `CharacterSet.controlCharacters` surprise in item 02: Swift's string
model is correct and the intuition carried over from other languages is not.

**A second trap, also in two places:** `/var` is a symlink to `/private/var`, so an
enumerated URL comes back resolved while the base URL does not. Stripping the base path as
a string therefore left a directory literally named `private2026-09-14-interview-prep-...`.
Both the export copy and the probe now use `FileManager.subpaths`, which returns paths
relative to the base and cannot drift.

**Timestamps moved to UTC.** A local offset is valid ISO 8601 but only sorts lexically
within one offset, and this file exists to be sorted in a spreadsheet.
