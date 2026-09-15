# Oral English — overview

> **Revision 2, 2026-09-14.** Revised after an adversarial review of revision 1; see
> `../../grill-report-2026-09-14.md`. The review found seven critical problems, including
> two defects in the build scripts and one factual claim about the toolchain that was
> simply wrong. Work item order changed as a result. Changes are summarized at the end of
> this file.

## Context

A macOS app for practicing spoken English. Paste an English paragraph, the app splits it
into sentences, a reference voice reads each one aloud, you record yourself reading it, and
the app compares your take against the reference both by ear and by scoring which words
were actually recognized. Practice also works at paragraph and whole-passage level. All
data stays on this machine in a browsable folder, and exports are named so they can be
found by date or subject later.

The reference voice quality is the point of the app, not a detail. Every English voice that
ships preinstalled is the lowest quality tier, which was the entire reason speech sounded
robotic. **Ava (Premium) was installed on 2026-09-14**, so that is now fixed, and the app
selects it automatically because it defaults to the best installed voice rather than the
system default.

## Decisions

Settled with the user before implementation. Not open for revisiting during the build.

| Decision | Choice |
| --- | --- |
| Stack | Native SwiftUI, hand-written build script, no Xcode project |
| Comparison | A/B playback plus on-device recognition scoring with a word diff |
| Storage | Visible folder in Documents, audio as `.m4a`, text and scores as JSON |
| History | Every take kept and timestamped, with per-sentence history and a best score |
| Signing | A self-signed code-signing certificate, so privacy grants survive rebuilds |
| Voice | Apple Premium voices now, behind a provider interface for a neural voice later |
| Naming | Date, then theme, then title, on folders and exports |
| UI | Native two-pane, deliberately restrained; see 04 and 13 |

Four further trade-offs were resolved during the review, with Gemini consulted on each.
They are recorded here because they change the shape of the code.

| Trade-off | Resolution | Why |
| --- | --- | --- |
| One document per passage, or one file per take | **One file per take** | Append becomes a single small file write instead of re-encoding the whole history. Corruption costs one take, not a session. Concurrent appends cannot collide because they write distinct paths. |
| App Sandbox | **No sandbox, plus the hardened runtime** | Sandboxing costs the predictable Documents path and needs a folder pick plus a security-scoped bookmark, which is real friction without Xcode. But the hardened runtime is one flag and blocks library injection, which matters because this app holds a standing microphone grant. |
| Where the pure scorer sits in the order | **Third, not ninth** | It is the consumer that determines the data model vocabulary. Built after the store, it forces a schema change once real user data exists. Built before, the schema is complete the first time. |
| iCloud Drive over Documents | **Keep Documents, detect sync, offer to relocate** | Gemini argued for moving to Application Support. That would override the user's explicit choice of a browsable Documents folder, so instead the app detects the synced case and offers a one-click move, defaulting to the user's preference. |

## Verified environment

All tested on this machine. Do not re-litigate, but re-check if the toolchain changes.

| Thing | Result |
| --- | --- |
| Xcode | Not installed. Command Line Tools only |
| SDK | 26.5, reached through a floating `MacOSX.sdk` symlink; five SDKs installed. `build.sh` echoes the resolved version every build |
| Swift | 6.3.3, builds SwiftUI `@main` apps with `-parse-as-library` |
| Strict concurrency | `-swift-version 6` compiles the declared view stack cleanly |
| macOS 14 APIs | `NavigationSplitView`, `ContentUnavailableView`, `.inspector`, `AVAudioApplication.recordPermission` available. Availability checking proven genuinely enforced against the deployment target |
| The delegate-shim shape | Compiles under strict concurrency: one warning, zero errors |
| `NLTokenizer` | Keeps "This is Dr. Smith's test, e.g. one sentence!" as one sentence. Measured 6 ms for 50,000 words |
| On-device recognition | `supportsOnDeviceRecognition` true **for en-US only**. `en-GB` and `zh-CN` report available but not on-device |
| Installed English voices | 42. **Ava (Premium) installed 2026-09-14**, identifier `com.apple.voice.premium.en-US.Ava`, en-US, tier premium. The other 41 are all lowest tier |
| Synthesis word callbacks | Fire correctly, 9 for a 9-word sentence. Need a live run loop |
| Audio formats | Synthesis to buffer gives **22050 Hz mono non-interleaved**; recording is specified at **44100 Hz mono**. They differ, which matters for item 10 |
| `AVAudioSession` | **Unavailable on macOS.** There is nothing to configure — but that also means route-change and interruption events must come from Core Audio or `AVCaptureDevice` instead, not that routes never change |
| Zip | Foundation has no zip API and `AppleArchive` is absent from this SDK, so `ditto` is required |
| **XCTest** | **Not available.** Ships with Xcode |
| **swift-testing** | **Available.** See below |
| Filesystem | Case-insensitive APFS. Path components cap at 255 characters; 256 fails |
| `tccutil reset` | Errors with OSStatus −10814 when TCC holds no record for the bundle id. That is benign, not a failure |

### Two corrections from revision 1

Revision 1 claimed swift-testing was unavailable "ships with Xcode, not Command Line
Tools". **That was wrong.** `Testing.framework`, `libTestingMacros.dylib`, and
`lib_TestingInterop.dylib` all ship with Command Line Tools. What misled the original
check was `swift test`, which fails because SwiftPM looks for Xcode's `Platforms`
directory and never wires up the framework search path. Driving `swiftc` directly works,
and `test.sh` now does so. A real suite runs in this repo with automatic discovery,
expression-capturing diagnostics, parameterized cases, and correct exit codes.

Revision 1 also claimed a hand-rolled runner "was verified working before the plan was
written". The prototype did work, but no such runner existed in the repo, and it is now
unnecessary. The claim is withdrawn.

## How testing works here

```bash
./test.sh              # whole suite
./test.sh --filter Scorer
```

That compiles `Sources/Core/`, `Tests/`, and `Sources/Tools/TestMain.swift` against
swift-testing, and runs them. No frameworks beyond Foundation and NaturalLanguage, no
permission prompts, about a second end to end. It is the loop to live in.

`test.sh` guards its own preconditions: it fails with a clear message if a toolchain
update moves any of the three swift-testing components, and it never pipes the runner,
because a pipeline's exit status is the last command's and would turn a failing suite into
a passing build.

**The architectural rule that makes this possible:** every file compiled by `test.sh`
imports only Foundation and NaturalLanguage. Note the rule is about the **test target's
import closure**, not about a directory name — revision 1 scoped it to `Sources/Core/`
while placing the store and the export logic under `Sources/Services/`, which meant the
two most important test suites could never have linked.

Enforcement is mechanical, not a checklist item. `scripts/check-core-imports.sh` runs at
the top of both `test.sh` and `build.sh` and fails on any import outside the allowlist.
Adding a genuinely pure dependency means adding one line to that allowlist, which is a
decision worth pausing on.

`Tests/HarnessTests.swift` guards the harness itself. Its assertions are trivially true;
the point is that a toolchain change which breaks discovery, parameterization, async, or
throw-checking fails there and names itself, rather than silently passing every other
suite in the project.

### What is genuinely test-first, and what is not

Being honest about this matters more than making every item look like TDD.

**Test-first, real red-green-refactor** — items 02, 03, 04, 05, and 11. Naming rules, the
sentence splitter, normalization, alignment and scoring, store persistence against a temp
directory, export naming and the CSV, and score calibration against committed fixtures.
That is now the majority of the logic worth trusting, and it comes first.

**Probe-first** — items 07, 08, 09, and 10. These drive AVFoundation and Speech, which
need a run loop, real hardware, or a privacy grant. Each starts by writing a small
command-line probe under `Sources/Tools/`, run with `./probe.sh <Name>`, that proves the
framework behaves as expected before any app code depends on it. A probe is not a unit
test, but it fails loudly and cheaply, which is the part that matters.

Revision 1 left more logic on the un-automated side than the constraints require. Several
pure units have been pulled into the test target: the audio activity state machine, chunk
planning and timestamp offsetting, UTF-16 range conversion, the permission degradation
matrix, voice tier ranking, the encoder settings dictionary, and the decibel conversion.
Each is named in its own item.

**Checklist-verified** — items 01, 06, 12, and 13. Bundle mechanics, permission states,
and UI. Each has an explicit pass or fail checklist, written before the code.

Never claim an item is done because it compiles. Each file states its own done-when
conditions, and **every** item now requires that `./test.sh` still passes — revision 1
asked for that in only two of twelve.

There is no continuous integration, so a git pre-commit hook running `test.sh` is item 01's
job. That is the whole CI story a single-machine project needs.

## Architecture

```
Oral-English/
  build.sh              compile, bundle, sign, install to ~/Applications
  run.sh                build then open
  test.sh               compile and run the suite
  probe.sh              compile and run one probe from Sources/Tools
  make-cert.sh          one-time self-signed code-signing certificate
  scripts/check-core-imports.sh
  Resources/Info.plist
  Sources/
    App/        OralEnglishApp.swift, AppModel.swift, Settings.swift
    Core/       Models.swift, Paths.swift, TextIntake.swift, SentenceSplitter.swift,
                Normalizer.swift, Scorer.swift, ChunkPlan.swift, ScoreCSV.swift,
                ExportNaming.swift, AppFailure.swift, Log.swift, PassageStore.swift,
                AudioActivity.swift, VoiceRanking.swift, PermissionMatrix.swift
    Services/   ReferenceVoice.swift, AppleVoiceProvider.swift, VoiceCatalog.swift,
                AudioRecorderService.swift, AudioPlayerService.swift,
                TranscriberService.swift, PermissionService.swift, ExportService.swift,
                PracticeController.swift
    Views/      RootView.swift, LibrarySidebarView.swift, PassageDetailView.swift,
                SentenceRowView.swift, TakeDetailView.swift, TransportBarView.swift,
                NewPassageSheet.swift, BannerView.swift, Styling.swift
    Tools/      TestMain.swift, probes
  Tests/        one file per Core type, plus Fixtures/
```

`PassageStore` lives in `Core/` rather than `Services/` because it needs only Foundation
and must be compiled by the test target. That costs some conceptual tidiness — an actor
doing real I/O sits beside pure value types — and buys the ability to test the two things
the review identified as mattering most.

`TargetRef` is the type that keeps the design small: a granularity plus a **stable UUID**,
naming what is being practiced. Because a sentence, a paragraph, and the whole passage are
all just a `TargetRef`, storage, scoring, history, and export have one code path instead
of three, and the UI has one row component instead of three.

Where that abstraction genuinely stops is worth stating, because revision 1 implied it did
not. Synthesis and transcription branch on utterance boundaries and audio duration by
framework necessity — that is expected, not a leak. A leak would be a granularity check
inside the store, the scorer, the export path, or the take history.

`PracticeController` holds **two** pieces of state, not one. An exclusive `audio` activity
covering idle, speaking, recording, playing a take, and playing A/B — genuinely exclusive
because there is one input and one output device — plus an `inFlight` set for background
work like scoring and baking. Revision 1 put scoring in the exclusive slot, which would
have blocked the next sentence while a take scored and contradicted its own requirement
that the UI stay responsive during scoring.

The exclusive audio axis is what structurally prevents recording while the reference is
playing, which in turn prevents the recognizer from transcribing the reference instead of
the user.

## Concurrency

Two isolation domains only: `@MainActor` for everything observable or touching
AVFoundation and Speech, and `actor PassageStore` for all filesystem work. Every model
type is a `Sendable` value type and nothing non-`Sendable` crosses a boundary.

The store's public API is **delta-shaped**: append a take, update a score. There is no
"save this whole passage" method, because that shape invites a caller to hold a stale copy
and write it back, losing a concurrent update. The verified delegate-shim pattern — one
shim per operation, continuation behind a lock, resumed exactly once on both the success
and error paths — is reused identically in four places, and now carries a **deadline**, so
a callback that never fires cannot hang the app forever.

## Storage

Root is `~/Documents/Oral English/`. One folder per passage, named date, theme, title,
short id. The date leads so a Finder sort by name is also chronological.

```
~/Documents/Oral English/
  README.txt                    explains the layout, and that these are voice recordings
  settings.json
  2026-09-14-interview-prep-the-fog-came-in-a1b2c3d4/
    passage.json                immutable: title, theme, dates, paragraphs, sentences
    takes/
      2026-09-14T201733Z-7f3a12.json
      2026-09-14T201733Z-7f3a12.m4a
    reference/
      <sentence-uuid>.m4a       only if baked
    incoming/                   in-progress recordings, adopted or quarantined on launch
```

One file per take, paired with its audio and sharing its name. Appending a take creates two
small files and rewrites nothing. `passage.json` changes only when the passage text does.

On iCloud: `~/Documents` is synced when the user enables Desktop and Documents in iCloud
Drive, which evicts audio to dataless placeholders and makes `replaceItemAt` generate
conflict duplicates. Sync is off on this machine today but one toggle away. The app detects
the ubiquitous case at launch and offers to move the library to Application Support, with a
reveal-in-Finder button; it does not silently relocate, because a browsable Documents
folder was the user's explicit choice.

## Work items

Numbered in **execution order**. The order changed from revision 1 so that all the
test-first work lands first.

| # | Item | Verification |
| --- | --- | --- |
| 01 | Bundle, signing, and a window | Checklist |
| 02 | Core models, text intake, and naming | Test-first |
| 03 | Normalizer and scorer | Test-first |
| 04 | Store and the first real screen | Test-first plus checklist |
| 05 | Export | Test-first |
| 06 | Permissions | Checklist |
| 07 | The reference voice | Probe-first |
| 08 | Recorder | Probe-first |
| 09 | Player and A/B | Probe-first |
| 10 | Transcription | Probe-first |
| 11 | Score calibration | Test-first |
| 12 | Paragraph and whole passage | Checklist |
| 13 | Polish | Checklist |

Items 01 to 05 are almost entirely `./test.sh` work and pin roughly 80 percent of the
logic worth trusting before any AVFoundation code can regress it. Items 06 to 10 make the
app real. Item 11 is where the scorer meets actual speech.

The cost of this order, stated plainly: the app is demoable later than in revision 1, where
item 03 gave a persistent app and item 04 made it speak. For a solo project that is a real
motivation cost. Two things reduce it. Item 04 still produces a working persistent app, and
before item 03 starts you should run the transcription probe once to capture three to five
real transcripts, which takes half an hour and stops the scorer being built against
imagined transcript shapes.

## Prerequisites to settle before writing code

Two claims are load-bearing and unproven. Both are cheap to check and both change a plan
if they fail.

1. ~~**Install a Premium voice and confirm it appears as Premium.**~~ **Done 2026-09-14.**
   Ava installed at 479 MB and reports as premium, en-US, identifier
   `com.apple.voice.premium.en-US.Ava`. Voice ranking selects it automatically, since the
   app defaults to the best installed voice rather than the system default. The blind
   listening comparison is on the Desktop awaiting a verdict.
2. **Prove that a privacy grant survives a rebuild.** There are currently zero code-signing
   identities on this machine. The entire development workflow assumes a stable certificate
   keeps the microphone grant. Complete the loop — build, launch, grant, rebuild, press
   record again — as the first act of item 01 and record the result.

## Out of scope

Accent and prosody grading beyond word recognition, any form of sync, iOS, importing
external audio as a reference, multi-user profiles, and **editing a passage's text after
the first take has been recorded**. That last one is new: revision 1 justified a design
decision by reference to editing, then never implemented it. Rename is supported; text
editing offers duplicate-with-edited-text instead, because re-splitting changes sentence
identity and would orphan every existing take.

## Open question, still unresolved

The user began stating a third requirement in a later message that was cut off after the
number and never completed. **Ask before assuming it is unimportant.** Revision 1 also had
item 10 claim it "closes the third requirement", which was a different enumeration and
made the open question look answered. That claim has been removed.

## What changed in revision 2

- Corrected the swift-testing claim and adopted it; deleted the hand-rolled runner.
- Restated the purity rule against the test target's imports and made it mechanical.
- Moved `PassageStore` and the pure export logic into the test-compiled tree.
- Reordered the work items so all test-first work comes first; split the scorer into build
  and calibrate.
- Changed persistence to one file per take.
- Split the activity enum into an exclusive audio axis and a background set.
- Made the store API delta-shaped and added deadlines to the delegate shims.
- Added a settings layer, a unified failure type, a logging layer, and a text intake step.
- Added the iCloud detection story, the recording staging directory, a single-instance
  lock, and a missing-audio story.
- Pinned `TargetRef.id` as a stable UUID and added the transcript type the scorer needs.
- Fixed the two build scripts, which could both fail silently.
- Put passage text editing out of scope and removed the false third-requirement claim.
