# 02 — Core models, text intake, and naming

**Status:** DONE — 2026-09-14
**Changed:** Sources/Core/Models.swift, AppFailure.swift, Log.swift, TextIntake.swift,
SentenceSplitter.swift, Paths.swift; Tests/ModelsTests.swift, AppFailureTests.swift,
TextIntakeTests.swift, SentenceSplitterTests.swift, PathsTests.swift;
scripts/check-core-imports.sh
**Verified:** ./test.sh (77 tests in 6 suites passed), ./build.sh (signature verified),
./scripts/check-core-imports.sh (passes), breaking one assertion exits 1 and names the test

**Verification style:** test-first. Real red-green-refactor, built entirely through
`./test.sh` with no app launch.

## Goal

The vocabulary of the app, the on-disk JSON shapes, the date-theme-title naming rules,
text sanitizing, and sentence splitting.

The test harness itself is **not** part of this item any more. `test.sh`,
`Sources/Tools/TestMain.swift`, `Tests/HarnessTests.swift` and
`scripts/check-core-imports.sh` already exist and are verified. Revision 1 had this item
build a hand-rolled runner; swift-testing ships with Command Line Tools, so that work is
deleted.

## Files

- `Sources/Core/Models.swift`
- `Sources/Core/Paths.swift`
- `Sources/Core/TextIntake.swift`
- `Sources/Core/SentenceSplitter.swift`
- `Sources/Core/AppFailure.swift`
- `Sources/Core/Log.swift`
- `Tests/ModelsTests.swift`, `PathsTests.swift`, `TextIntakeTests.swift`,
  `SentenceSplitterTests.swift`, `AppFailureTests.swift`

## Red — text intake

Sanitize once, at the entry point, before anything else sees the text. Revision 1 had no
intake step, and a NUL character survives into storage and silently collapses a file URL's
path to the empty string, which would then be misdiagnosed as the relative-path bug item 05
warns about.

| Input | Expected |
| --- | --- |
| `"One.\0Two."` | NUL stripped, 2 sentences, no unprintable leading character |
| text containing `\u{07}` | control character stripped |
| `"a\r\nb"` and `"a\rb"` | normalized to `\n` before any splitting |
| text with a zero-width space | left intact; it is not a control character and does not split |
| combining characters | NFC-normalized, so JSON and the APFS filename agree on composition |
| `"\n"` and `"\t"` | preserved; they are the only control characters with meaning here |

## Red — sentence splitting

| Input | Expected |
| --- | --- |
| `"This is Dr. Smith's test, e.g. one sentence!"` | exactly 1 sentence |
| `"One. Two. Three."` | 3 sentences, no leading or trailing whitespace on any |
| `"First para.\n\nSecond para."` | 2 paragraphs, 1 sentence each |
| `"Line one.\nLine two."` | **1 paragraph**, 2 sentences |
| `"First para.\r\n\r\nSecond para."` | 2 paragraphs |
| `"Then, at 4 p.m., it moved on."` | 1 sentence |
| `"   "` and `""` | 0 paragraphs, 0 sentences, no crash |
| `"No terminal punctuation"` | 1 sentence |
| A 3-paragraph text | global sentence indices contiguous from zero, each `paragraphIndex` correct |
| 50,000 words | completes well under a second; measured 6 ms |

**The algorithm changed.** Revision 1 said "split on blank lines, falling back to single
newlines when that yields one chunk", which contradicts the fourth row: one chunk triggers
the fallback and yields 2 paragraphs. There is no implementation satisfying both. The
fallback is deleted. Normalize line endings in intake, then split paragraphs on two-or-more
newlines only.

The cost: text pasted from a source that uses single newlines as paragraph breaks collapses
into one paragraph. That is the right default, since `NLTokenizer` still finds the correct
sentences and only paragraph-level practice is affected. The new-passage sheet's live
paragraph and sentence count makes any miscount visible before the user commits.

## Red — naming

| Input | Expected folder name |
| --- | --- |
| title "The fog came in", theme "Interview prep", 14 Sep 2026 | `2026-09-14-interview-prep-the-fog-came-in-<id>` |
| same, no theme | `2026-09-14-the-fog-came-in-<id>` |
| "Café résumé" | `cafe-resume`, accents folded |
| `"中文标题"` | non-empty, transliterated, **never** empty |
| `"???"`, `"…"`, `"🎉🎉🎉"`, `"-"` | non-empty fallback such as `untitled` |
| `""` and `"   "` | non-empty fallback |
| `"../../evil"` | `evil` — one path component, never joined |
| `".hidden"` | `hidden`, no leading dot |
| `"-rf"` | `rf`, no leading hyphen |
| a 500-character title | assembled component capped at 255 characters, truncated on a hyphen boundary |
| any input | **no double hyphen anywhere**, no trailing hyphen |
| two titles slugging identically | names differ via the short id |
| two ids differing only in case | cannot be generated; the alphabet is lowercase |

The slug spec is now a **positive whitelist**, not a description of its output: fold to
lowercase ASCII, keep only `[a-z0-9]`, map every other run to a single hyphen, trim leading
and trailing hyphens, cap the length, and substitute a fixed placeholder when empty.
Revision 1 described the output and so never caught the empty-slug case, which produces
exactly the double hyphen it forbade.

The short id is lowercase hex. The filesystem is case-insensitive APFS, verified, and since
the slug is already lowercased the id is the only differentiator — a mixed-case alphabet
would let two passages name the same directory, and `mkdir -p` would merge them silently.
Create the passage folder with `withIntermediateDirectories: false` so a collision throws.

Also assert: no generated component contains a colon (Finder renders it as a slash) or a
control character, and two takes recorded in the same second get distinct filenames.

Pin an explicit calendar and time zone. The date leads every folder name, so a passage
created at 23:30 local time would otherwise disagree with its own `createdAt`. Test that
boundary.

## Red — models

- A `Passage` and a `Take` each round-trip through encode and decode and compare equal.
- Encoded dates are ISO 8601, asserted by decoding **every** date field and comparing, not
  by grepping for a literal year. Revision 1 grepped for `"2026-`, which passes on partial
  compliance and goes vacuous next year.
- `schemaVersion` higher than supported gives a recognizable error. Also test missing,
  lower, and malformed versions; revision 1 tested only higher.
- A v1 fixture decodes with the current decoder. This is the migration seam: retention is
  unbounded and this review alone shows the schema must change at least once, so a forward
  guard with no upgrade path would render a library permanently broken.
- `bestTake(for:)` returns the highest accuracy, and `nil` with no takes and no scores.
- A `TargetRef` still resolves after the passage is reloaded.

## Green — the model shapes

`Models.swift` holds only `Codable`, `Sendable` value types.

**`TargetRef` is a granularity plus a stable `UUID`.** Sentence and paragraph refs carry the
UUID minted at split time and stored on `Sentence` and `Paragraph`; whole-passage uses the
passage's own id. The CSV's target index is derived at export time from current ordering and
**never stored in the ref**. Revision 1 left the id unspecified while export asked for an
index, which would have silently re-pointed every historical take on any re-split.

**`Transcript` and `TranscriptWord` live here**, carrying text, per-word confidence, start,
and duration. Revision 1 omitted them, and the scorer needs mean confidence — so the on-disk
schema was provably incomplete, and the omission would have surfaced at item 10, after nine
files and real user data depended on the shape.

**Takes are separate files, not an array.** `passage.json` holds only the immutable passage:
title, theme, dates, paragraphs, sentences, schema version. Each take is its own small JSON
beside its audio, sharing its name. Appending writes two small files and rewrites nothing.
Revision 1 kept every take in one pretty-printed array rewritten in full on every append and
re-score, with unbounded retention, which is rewrite amplification and makes one corrupt file
cost a whole session.

Each take snapshots the `referenceText` it was scored against, and `audioPath` is **relative**
so a zipped and moved folder still plays. There is no stored best-take field; compute it.

`AppFailure` is one error enum covering denial, missing offline model, no speech detected,
recorder start failure, device loss, out of space, library unavailable, corrupt passage,
missing audio, schema mismatch, export failure, and timeout. Each case carries an optional
underlying error for the log and exposes a user message. Revision 1 had five incompatible
failure representations across six items and then demanded uniform copy over all of them via
a mapping layer nothing owned.

Test the copy, since hand-checking is otherwise the only verification: every case's message
is non-empty, one sentence, contains no `NSError` or `Error Domain` or first person, and
names an action.

`Log.swift` is Foundation-only, one logger per subsystem over `os.Logger`. The rule is that
every `catch` logs the full error alongside the mapped user copy. Revision 1 had no
observability at all while documenting five silent failure modes, and item 13 forbade showing
raw error text, so a silent failure left no trace anywhere.

## Refactor

Pull the slug out once both folder naming and export naming need it. Export names are shaped
differently, so add a **golden-file naming test**: a committed table of inputs to exact
expected folder and export names, so any slug change fails loudly instead of silently
splitting the library between old and new folders.

## Done when

- [x] `./test.sh` passes with every table row above asserted.
- [x] Deliberately breaking one assertion makes `./test.sh` exit non-zero and name the test.
- [x] `./scripts/check-core-imports.sh` passes.
- [x] The golden naming table is committed, in `Tests/PathsTests.swift`.


## Findings while executing this item

1. **`CharacterSet.controlCharacters` includes Unicode *format* characters, not only C0
   controls.** Verified by probe: U+200B zero-width space, U+200E left-to-right mark and
   U+FEFF are members; U+00A0 non-breaking space is not. So `TextIntake` strips invisible
   formatting characters as well as control characters. That is the behavior we want — an
   invisible character inside a word would silently break word matching and produce a diff
   nobody could explain — but it was not what the plan predicted, and it is now documented
   and tested in both directions.
2. **`os` was added to the import allowlist.** `Log.swift` needs `os.Logger`, which is not
   Foundation. Verified that it constructs and logs inside a plain command-line binary with
   no permissions and no run loop, so it does not compromise the fast test loop. This is the
   one addition to that allowlist and the reason is recorded in the script.
3. **The transliteration path matters more than expected.** A CJK title yields a real slug
   (`zhe-shi-yi-ge-biao-ti`) rather than the `untitled` fallback, which keeps the folder
   identifiable in Finder. The fallback now only triggers for titles with no transliterable
   content at all, such as `"???"` or an emoji run.
