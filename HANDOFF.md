# Handoff

Written 2026-09-15, so this session's context can be discarded without losing anything.
Everything here is either verified or explicitly marked unverified.

**Read order for a fresh session:** this file, then `docs/plan/00-overview.md`, then the
work item you are about to touch. The grill report in `grill-report-2026-09-14.md` is
history — its findings are already folded into the plan and the code.

## What this is

A macOS app for practicing spoken English. Paste a paragraph, hear each sentence read by a
native-sounding reference voice, record yourself reading it, and see which words were
actually understood. All data local, in a browsable folder under Documents.

Built without Xcode, with Command Line Tools only.

## Current state

| | |
| --- | --- |
| Commits | 14, all on the default branch |
| Swift sources | 53 files, about 9,700 lines |
| Tests | **252 passing in 20 suites**, about half a second |
| Build | Clean, signed with `Authority=Oral English Dev`, installed to `~/Applications/Oral English.app` |
| Probes | 11 under `Sources/Tools` |
| Plan items | 6 done, 4 partial, 1 blocked, out of 13 |

```bash
./test.sh        # 252 tests, no permissions needed, the loop to live in
./build.sh       # compile, sign, install
./run.sh         # build then open
./probe.sh       # lists the probes
```

A git pre-commit hook runs `./test.sh` and blocks the commit on failure. There is no CI;
that hook is the whole regression story.

## The three things that actually block progress

Everything else is done or is a partial with its remaining gates listed in its own plan
item. These three are the real queue, in order.

### 1. Is per-word recognizer confidence non-zero on this machine?

**This is the highest-value unknown.** The scorer's hard-to-hear rule turns on mean
confidence, and `SFTranscriptionSegment.confidence` is commonly reported as `0.0` for
on-device results. If it is uniformly zero here, every take trips hard-to-hear and the app
never shows a score again. Item 03 already specifies the fallback: derive the signal from
recorder metering plus the missed-word ratio.

Settle it by recording yourself and transcribing:

```bash
ORAL_PROBE_DIRECT=1 ORAL_SENTENCE="The fog came in on little cat feet." \
  ./probe.sh RecordProbe ~/Desktop/take.m4a 8

./probe.sh TranscribeProbe ~/Desktop/take.m4a "The fog came in on little cat feet."
```

The first speaks the prompt through Ava, counts down, records, and prints a live level bar.
The second reports the confidence distribution and says plainly which case you are in.

### 2. Nothing has been recorded or transcribed yet

Item 08's encoder path, delegate await and staging are proven — 368,576 frames at 44100 Hz
mono, finalized cleanly. But **no audio has ever been captured**: every run measured peak
level 0.00. Ruled out: permission granted, built-in mic is the live default, input volume
37, not muted. So it is either that nobody spoke during the window, or the terminal's grant
yields a silent stream.

Item 10 has transcribed nothing at all, so the format conversion, the chunking on real
audio, and the error mapping are all unexercised.

### 3. Item 11 calibration needs about fifty labelled takes

The harness, fixture format, category counts, tuning and held-out split, and the acceptance
metric are all committed in `Tests/Fixtures/README.md`. The scorer currently runs on
defaults tuned against synthetic cases only. `CalibrationTests` prints
`CALIBRATION NOT RUN` rather than passing quietly.

## Environment facts, all verified on this machine

Do not re-derive these. Re-check only if the toolchain changes.

| Thing | Result |
| --- | --- |
| Xcode | Not installed. Command Line Tools only, SDK 26.5 |
| Swift | 6.3.3. Strict concurrency (`-swift-version 6`) is on |
| **XCTest** | **Unavailable.** Ships with Xcode |
| **swift-testing** | **Available**, and in use. `swift test` fails because SwiftPM looks for Xcode's Platforms directory; driving `swiftc` with `-F`, `-plugin-path` and two `-rpath` flags works. `test.sh` does this and guards the three paths |
| On-device recognition | **en-US only.** `en-GB`, `en-AU`, `zh-CN` all report available with no on-device model, which is why the locale is pinned |
| Voices | 42 English. **Ava (Premium) installed**, `com.apple.voice.premium.en-US.Ava`. The other 41 are lowest tier |
| Audio formats | Synthesis 22050 Hz mono non-interleaved; recording 44100 Hz mono. They differ, which is why the transcriber converts |
| `AVAudioSession` | Unavailable on macOS. Route-change events must come from Core Audio or `AVCaptureDevice` instead — its absence is not the absence of the problem |
| Zip | No Foundation API, `AppleArchive` absent from this SDK, so `ditto` |
| Filesystem | Case-insensitive APFS, 255-character path components |
| SIP | Enabled. `/System/Library/AssetsV2` not writable, so voices cannot be installed from the command line |

## Traps that cost real debugging time

These are all fixed, and all recorded in the plan item they belong to. Listed here because
they are the things a fresh session would otherwise rediscover.

1. **A CRLF pair is one `Character` in Swift.** So `case "\r"` never matched and
   `contains("\r")` was false, which broke CSV parsing and quoting. Both now work on
   `Unicode.Scalar`. (Item 05)
2. **`CharacterSet.controlCharacters` includes Unicode *format* characters.** U+200B and
   U+FEFF are members, U+00A0 is not. Text intake strips them, deliberately. (Item 02)
3. **`/var` is a symlink to `/private/var`.** Stripping a base path as a string produced a
   directory literally named `private2026-09-14-...`. Use `FileManager.subpaths`. (Item 05)
4. **ISO 8601 encoding drops fractional seconds**, so a `Date` round trip was not an
   identity. Everything goes through `Date.wholeSecond`. (Item 04)
5. **`AVAudioRecorder.settings` is empty until the recorder is prepared**, so there is no
   round trip to confirm a key was accepted. A sample rate passed as `Int` is silently
   ignored, which is why its type is asserted. (Item 08)
6. **The delegate fires before the caller awaits.** `OneShot` originally resumed only an
   already-waiting continuation, so every take was reported not cleanly finalized while the
   audio was perfect. It now buffers the first result. This shim is shared by the recorder,
   player, synthesizer and recognizer. (Item 08)
7. **Voice ranking picked a novelty voice.** Every preinstalled voice is the same tier, so
   the tie-break fell through to alphabetical and selected Albert, a MacinTalk toy. Ranking
   now includes a voice family inferred from the identifier. (Item 07)
8. **Ava's installed identifier is not its advertised one.** The catalog says
   `com.apple.ttsbundle.Ava`; installed it reports `com.apple.voice.premium.en-US.Ava` and
   is named "Ava (Premium)". Both prefixes are recognized and pinned by test. (Item 07)
9. **Word callbacks are not one per word**, and the count varies by voice. Consume ranges as
   they arrive. A voice emitting none is a supported case. (Item 07)
10. **A probe cannot get a microphone grant from a non-interactive session.** Four routes
    tried, all documented in item 08. Neither an embedded plist, nor a real bundle, nor an
    `NSApplication` host, nor a trusted location works: macOS denies rather than prompting.
    `ORAL_PROBE_DIRECT=1` borrows the terminal's grant and must never touch `Speech`,
    because merely reading the recognition status is privacy-gated and kills the process.
11. **A probe that pumps the run loop cannot be `async`.** `RunLoop.current` is unavailable
    from an async context. `VoiceProbe` is synchronous; `BakeProbe` is async because its
    continuation is driven by the concurrency runtime. (Item 07)
12. **`grep -q` under `set -o pipefail` inverts an assertion.** grep exits on match,
    codesign takes SIGPIPE, and the pipeline reports failure on the success path. Capture
    output, then match. (Item 01)

## Architecture, in one screen

```
Sources/
  Core/      Foundation + NaturalLanguage + os ONLY. Compiled by test.sh.
             Models, Paths, TextIntake, SentenceSplitter, Normalizer, Scorer,
             ChunkPlan, AudioLevel, AudioActivity, VoiceRanking, PermissionMatrix,
             ScoreCSV, AppFailure, Log, BannerKind, PassageStore
  Services/  AVFoundation, Speech, AppKit. ReferenceVoice + AppleVoiceProvider,
             VoiceCatalog, AudioRecorderService, AudioPlayerService,
             TranscriberService, PermissionService, ExportService,
             PracticeController, DelegateShim, LibraryLock, Workspace
  Views/     SwiftUI
  App/       OralEnglishApp, AppModel, Settings
  Tools/     TestMain, ProbeApp, 11 probes
```

**The one rule that matters:** every file compiled by `test.sh` imports only Foundation,
NaturalLanguage and `os`. Enforced mechanically by `scripts/check-core-imports.sh`, which
runs at the top of both `test.sh` and `build.sh`. Break it and the fast test loop dies.
`PassageStore` lives in `Core/` for exactly this reason, even though it does real I/O.

**`TargetRef`** is a granularity plus a stable UUID. Because a sentence, a paragraph and the
whole passage are all just a `TargetRef`, storage, scoring, history and export have one code
path. Verified clean: zero granularity branches in the store, scorer, normalizer, CSV or
export.

**`PracticeController` has two state axes**, not one: an exclusive `audio` activity, because
there is one input and one output device, plus an `inFlight` set for scoring and baking. The
exclusive axis is what makes recording-while-the-reference-plays impossible.

**Concurrency is two domains:** `@MainActor` for anything touching AVFoundation or Speech,
and `actor PassageStore` for the filesystem. The store's API is delta-shaped — append a
take, update a score — with no whole-document save, so a stale caller copy cannot drop a
concurrent append.

## Storage

`~/Documents/Oral English/`, one folder per passage named date, theme, title, short id.
`passage.json` holds only the immutable passage; **each take is its own small file** beside
its audio, sharing a stem. Appending writes two small files and rewrites nothing.

`README.txt` in the library discloses that the `.m4a` files are recordings of the user's
voice, kept until deleted, included in backups, and uploaded if iCloud Desktop and Documents
sync is switched on. The app detects the synced case and offers to relocate rather than
silently corrupting.

## Decisions already settled — do not relitigate

From the user directly: native SwiftUI without Xcode; A/B playback **plus** word-level
scoring; visible storage in Documents; every take kept forever; a self-signed certificate so
privacy grants survive rebuilds; Apple Premium voices behind a provider interface for a
neural voice later; date-plus-theme naming.

From the review, with Gemini consulted: one file per take rather than one document; no
sandbox but **with** the hardened runtime; the pure scorer third rather than ninth; keep
Documents and detect iCloud rather than moving to Application Support.

On the UI, the user reviewed three mockups, chose the native two-pane direction, then asked
for it simpler. **Seven elements were explicitly rejected and must not creep back:** a
permanent status chip row, filled score rings, borders between sentence rows, paragraph
label dividers, an always-visible take history table, a permanent voice banner, and keyboard
shortcuts printed in the footer.

## Still open

**A third requirement the user began stating was cut off after the number and never
completed.** Ask before assuming it is unimportant. Everything else they asked for is built.

## Honesty standard used throughout

Each plan item carries a `**Status:**` stamp and a checklist. A box is ticked only when
something ran. Gates needing a human — speaking, listening, clicking Allow, judging the UI —
are marked blocked rather than assumed, because screen recording and assistive access are
both denied to this session. If a fresh session finds a ticked box it cannot reproduce, the
stamp is wrong and should be corrected rather than worked around.
