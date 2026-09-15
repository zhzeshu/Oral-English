# 04 — Store and the first real screen

**Status:** DONE — 2026-09-14 (three gates BLOCKED on the user, see below)
**Changed:** Sources/Core/PassageStore.swift, Sources/App/AppModel.swift,
Sources/App/Settings.swift, Sources/App/OralEnglishApp.swift,
Sources/Services/LibraryLock.swift, Sources/Services/Workspace.swift,
Sources/Views/{RootView,LibrarySidebarView,PassageDetailView,SentenceRowView,
NewPassageSheet,BannerView,Styling}.swift, Sources/Tools/StoreProbe.swift, probe.sh,
Tests/PassageStoreTests.swift
**Verified:** ./test.sh (157 tests in 9 suites passed, 22 store rows), ./build.sh clean,
./probe.sh StoreProbe (on-disk layout inspected), single-instance lock confirmed by
launching a second copy and observing it acquire no lock
**Blocked gates:** the three that need a human at the keyboard — see the checklist.

**Verification style:** test-first for the store, checklist for the screen.

## Goal

Persistence, plus enough UI to paste a paragraph and see it split into sentences. At the end
of this item the app is useful and remembers things.

## Files

- `Sources/Core/PassageStore.swift` — in `Core/`, not `Services/`, because it needs only
  Foundation and **must** be compiled by the test target. Revision 1 put it in `Services/`
  while scoping the test target to `Core/`, so its eleven test rows could never have linked.
- `Sources/App/AppModel.swift`, `Sources/App/Settings.swift`
- `Sources/Views/RootView.swift`, `LibrarySidebarView.swift`, `PassageDetailView.swift`,
  `SentenceRowView.swift`, `NewPassageSheet.swift`
- `Tests/PassageStoreTests.swift`

## Red — write these tests first

Every test creates its own temp root and removes it after, so the suite never touches the
real library.

| Test | Assertion |
| --- | --- |
| create then load | a passage created and reloaded compares equal |
| library creation | `ensureLibrary` is idempotent and creates the root plus `README.txt` |
| scan | three passages produce three summaries with correct titles and counts |
| corrupt `passage.json` | that passage is marked broken, **the others still load** |
| corrupt one take file | that take is skipped, the passage and its other takes still load |
| atomic save | no `.tmp` file remains after a save |
| pre-existing `.tmp` | a stale temp from a crashed run is ignored or cleaned on load |
| append take | returns a passage whose take count grew by one, with the right `TargetRef` |
| **stale-copy append** | load into a cached copy, append A through the store, then append B **from the stale copy** — both survive |
| update score | scoring take A does not disturb take B |
| concurrent appends | two concurrent appends lose neither |
| second writer | `passage.json` modified underneath between load and save: the append retries against new content rather than overwriting |
| delete | the folder is gone from the library root and present in the Trash |
| relative paths | a saved `audioPath` does not start with a slash and does not contain the temp root |
| import recording | a temp audio file moved in returns a relative path and the file exists there |
| missing audio | a take whose audio file is absent loads with that take marked unplayable, rather than failing the passage |
| read-only directory | a failed save **surfaces an error** and does not report the take as saved |

The stale-copy and second-writer rows are new and are the ones that matter. Revision 1's
concurrent-append test passes trivially: an actor serializes calls to itself, so it proves
nothing. The real lost update lives one layer up, in read-from-cache, mutate, write-back
across an `await`, and across two app instances.

The read-only row matters because item 08 treats "audio the user already spoke must never be
discarded" as a cardinal rule, and a silently failed save discards it.

## Green

`actor PassageStore` owns the folder layout, all JSON, and all file creation, move and
delete. Other services may open, read and write audio bytes only at URLs the store hands
them, and must never construct a path or choose a filename. Revision 1 claimed the store
owned *every* filesystem touch, which is false for five services and would have been either
silently violated or satisfied by funneling audio bytes through an actor.

**The public API is delta-shaped.** Append a take; update a score. There is deliberately no
`save(_ passage:)`, because that shape invites a caller to hold a stale copy and write it
back. `AppModel.loaded` becomes a read-through cache replaced by the actor's return value,
never a write source.

Saving is atomic: encode, write to a temp file in the same directory, then `replaceItemAt`.
Before replacing, compare the modification date recorded at read; if it moved, reload and
re-apply rather than overwriting. Deleting moves to the Trash rather than unlinking, because
these are the user's recordings.

**A single-instance lock.** Take an exclusive `flock` on a lock file in the library root at
launch; if held, say so and terminate. `build.sh` leaves a launchable copy in `build/` and
installs another to `~/Applications`, both with the same bundle id, so two instances against
one library is an easy accident — and atomic writes make it worse, guaranteeing each write is
individually clean so there is no corruption to detect. Use `flock`, released by the kernel
on process death, not a PID file that strands after a crash.

**Repair, not just detection.** A broken summary carries the folder URL and the decode error,
and its sidebar row offers reveal-in-Finder and move-to-Trash operating on the raw URL, since
there is no decodable passage to act on. On a decode failure, copy the bad file aside before
any later write can clobber it, so a stray comma is hand-fixable. On scan, flag takes whose
audio does not resolve and offer to drop those records.

No index file: the folders are the source of truth. That means re-asserting `ensureLibrary`
before every write and surfacing a failure rather than silently recreating an empty library
if the folder was renamed mid-session.

**iCloud.** Detect the ubiquitous case at `ensureLibrary` and offer to move the library to
Application Support, with reveal-in-Finder. Do not relocate silently; a browsable Documents
folder was the user's explicit choice. Under sync, audio is evicted to dataless placeholders
and `replaceItemAt` generates conflict duplicates — revision 1 never mentioned iCloud at all.

`Settings.swift` is an observable type over `UserDefaults` holding the selected voice, rate,
whether the voice banner has been dismissed, and the last selected passage. Voice and rate
are **app-wide, not per-passage**. Revision 1 had six requirements needing this and no owner.

`AppModel` is the single root object and the only thing views talk to. It also holds a
`[TargetRef: RowSummary]` map — target text, best accuracy, take count, cached diff string —
recomputed once per passage mutation. Rows read only their own summary, so rendering is
constant-time in take count and `bestTake` is never called from a view body.

## The screen

Restrained by rule. The sidebar is a plain list under small theme headings, each entry a
title and a date, selection marked by a quiet fill. No counts, no rings, no progress bars.

The detail pane leads with the title, one muted meta line giving theme, date and the current
app voice, and an ellipsis menu. Sentences run as a single column with **no borders and no
paragraph labels**, separated by whitespace alone. Nothing else is on screen yet.

The new-passage sheet takes a title, an optional theme with autocomplete over themes already
used, and the pasted text, and shows a live count of detected paragraphs and sentences.
Debounce it by about 300 ms; a `TextEditor` bound to a multi-thousand-word string re-lays out
on every keystroke. Run a language check on the paste and show a non-blocking note if the
text does not look like English — a soft hint, never a block, because detection on short text
is unreliable and the alternative failure is a confident zero score the honesty constraints
cannot catch.

## Done when

- [x] `./test.sh` passes, including every row above.
- [ ] Pasting a multi-paragraph passage shows the right sentences. *(BLOCKED: the splitting
      is verified by test and by probe — 3 sentences across 2 paragraphs, with
      "Then, at 4 p.m., it moved on." kept whole — but the rendering could not be checked
      visually. Screen recording and assistive access are both denied to the terminal, so
      no screenshot or accessibility dump was possible.)*
- [x] The library folder contains a date-theme-title folder whose `passage.json` is readable
      in a text editor, with takes as separate files.
- [ ] The Documents privacy prompt appeared once and was granted. *(BLOCKED on the user:
      needs a click on Allow. The app has not yet written to the real Documents folder —
      the UI run used a temporary library via the settings override, deliberately, so
      nothing real was touched.)*
- [ ] Quitting and relaunching restores the library and the last selection. *(PARTIAL: the
      last folder is persisted to user defaults and read back at bootstrap, and the library
      scan is covered by test. The round trip through the real UI was not exercised.)*
- [x] Two passages with the same title produce two distinct folders.
- [x] Hand-corrupting one `passage.json` leaves the rest working, and that row offers reveal
      and delete.
- [x] Launching a second instance is refused with a message.
- [x] Renaming the library folder mid-session surfaces a message and does not create a second
      empty library.


## Findings while executing this item

1. **Dates did not survive a round trip.** The `.iso8601` coding strategy writes no
   fractional seconds, so a `Date` carrying them decoded to a different value and an
   equality assertion failed on two structures that printed identically. Every date entering
   the model now goes through `Date.wholeSecond`. Encoding fractions would also have worked,
   but whole seconds keep `passage.json` readable, which is the entire reason for storing it
   in the open.
2. **Probes need an explicit entry point.** Top-level code is only allowed in a file named
   `main.swift`, so `probe.sh` compiles with `-parse-as-library` and each probe uses `@main`.
   Two async details also bite: `FileManager.enumerator`'s iterator is unavailable from an
   async context, and an actor's methods need `await` even for pure path math.
3. **The second-instance path needed to actually quit.** The lock correctly refused the
   second instance, but the app then sat there with an error alert and a dead window.
   It now says why and quits, which is what the plan asked for.
4. **Screen recording and assistive access are both denied to the terminal**, so the three
   UI gates above cannot be machine-verified from here. That is a real limit on what
   "verified" can mean for the view layer, and it is why those gates are marked blocked
   rather than assumed.

## What the probe showed

```
folder: 2026-09-14-interview-prep-the-fog-came-in-9946cd21
sentences: 3, paragraphs: 2
  [0] p0: The fog came in on little cat feet.
  [1] p0: It sat looking over harbor and city.
  [2] p1: Then, at 4 p.m., it moved on.
takes: 2, missing audio: 0

  passage.json  (1426 bytes)
  takes/2026-09-15T045818Z-6fdea9.json  (351 bytes)
  takes/2026-09-15T045818Z-6fdea9.m4a
  takes/2026-09-15T045918Z-740434.json  (351 bytes)
  takes/2026-09-15T045918Z-740434.m4a
```

One 351-byte file per take, paired with its audio and sharing a stem. Appending rewrites
nothing.
