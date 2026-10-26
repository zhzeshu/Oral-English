# Handoff

Written 2026-09-15; the transcription and permissions sections were revised later the
same day. So this session's context can be discarded without losing anything.
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
| Commits | 16. The first 14 are on the default branch; the Speech API migration and the icon are on `speech-api-migration` |
| Swift sources | 53 files, about 9,700 lines |
| Tests | **261 passing in 21 suites**, about half a second |
| Build | Clean, signed with `Authority=Oral English Dev`, installed to `~/Applications/Oral English.app` |
| Probes | 13 under `Sources/Tools` (AssetProbe and ModernTranscribeProbe added 2026-09-15) |
| Icon | `Resources/AppIcon.icns`, drawn in CoreGraphics. `./make-icon.sh` regenerates it from `Sources/Icon/MakeIcon.swift` |
| Plan items | 6 done, 4 partial, 1 blocked, out of 13. Item 06's DONE stamp was corrected to PARTIAL on 2026-09-15 |

```bash
./test.sh        # 261 tests, no permissions needed, the loop to live in
./build.sh       # compile, sign, install
./run.sh         # build then open
./probe.sh       # lists the probes
```

A git pre-commit hook runs `./test.sh` and blocks the commit on failure. There is no CI;
that hook is the whole regression story.

## Status of the three former blockers — all resolved or answered 2026-09-15

The three items that used to head this file are done. Read
`docs/plan/10-transcription.md` for the full account; the short version:

### 1. Is per-word confidence non-zero? YES — and it correlates with correctness

Settled. mean **0.7776**, 8 distinct values, min 0.194, max 0.986. **Item 03's
hard-to-hear rule stands as designed; the metering fallback is not needed.**

On the one take measured, both misrecognised words scored below 0.45 while every correct
word exceeded 0.94. Promising, but n=1 — treat it as a hypothesis for the item 11 corpus to
test, not a design input.

Two conditions: it needs `attributeOptions: [.transcriptionConfidence]` (without it no
confidence is reported at all), and it needs the **modern** Speech API.

### 2. Recording works, and real speech has been captured

`~/Desktop/take.m4a` — 8.40s of "The fog came in on little cat feet." Verified independently
of the level meter by decoding to PCM: 370,624 frames at 44100 Hz, RMS −21.4 dBFS, speech in
seconds 0–4. The old peak-0.00 runs were nobody speaking, not a silent stream.

**It clips at 0 dBFS.** Trim input gain before recording item 11's fifty takes; a clipped
corpus would tune the scorer against distortion.

### 3. Item 11 still needs ~50 labelled takes

Unchanged in substance, but it is now an hour of reading rather than a design problem — with
one new prerequisite: **decide the transcription API first** (below). Fixtures store
transcripts with confidences, so they are only reusable if produced by the API that ships.
The audio would stay valid; the transcripts would not.

## Migration done 2026-09-15: transcription runs on the modern Speech API

`TranscriberService` was rewritten on `SpeechAnalyzer`/`SpeechTranscriber`. The deployment
target is now **macOS 26.0** (`build.sh`, `test.sh`, `probe.sh`) and **no legacy fallback
was kept** — legacy `SFSpeechRecognizer` on-device returns an empty transcript with no error
on this OS, so a fallback would be untested code that is known-broken where it would run.

The public API did not change, so no caller moved. Full pipeline verified end to end:

```
mean confidence 0.677    timings monotonic: yes
scored: accuracy 69 percent, verdict clear
  6 matched, 0 close, 1 wrong, 1 missed, 1 extra
  words to work on: The, fog
```

Those two flagged words are the two lowest-confidence words, and the verdict is `clear`
rather than `hardToHear` — item 03's rule behaving correctly on real speech.

**A 92-second file transcribes in one pass**, 87 words, complete coverage, monotonic
timings, 0.52s. So `ChunkPlan` is no longer needed for file transcription. It is
deliberately **not deleted** — its 13 tests are the only coverage of monotonic timings
across boundaries, and streaming recognition is not built yet.

**Two bugs the migration exposed, both fixed.** `offlineModelAvailable` came from
`supportsOnDeviceRecognition`, which reported `true` with no model installed, so the app
would have promised scoring and failed at score time; it now reads `AssetInventory.status`
via `PermissionService.refreshModelAvailability()`. And the missing-model banner offered
"Open settings" pointing at a privacy pane that cannot fix a missing model; it is now
"Download model" and calls `AppModel.installSpeechModel()`.

## What is actually left

1. **Item 11's corpus** — ~50 labelled takes, about an hour of reading. Trim input gain
   first; the one take so far clips at 0 dBFS. This is now the critical path.
2. **In-app gates for items 06, 08 and 10** — one record tap in the real app, the transcript
   showing in the expanded row, the no-speech message, and the three interruption paths
   (device unplug, force quit, sleep). All need a human using the app.
3. **Recognition accuracy is not good yet.** "The fog came in on little cat feet." came back
   as "Oh, came in on a little cat feet." — two errors, so item 10's within-one-word gate is
   still PARTIAL. The take clips, which is a plausible cause. Re-test on a clean recording
   before concluding anything about the recognizer.
4. **The third requirement the user never finished stating.** Still unresolved, still the
   only non-technical item. Ask.

## Environment facts, all verified on this machine

Do not re-derive these. Re-check only if the toolchain changes.

| Thing | Result |
| --- | --- |
| Xcode | Not installed. Command Line Tools only, SDK 26.5 |
| Swift | 6.3.3. Strict concurrency (`-swift-version 6`) is on |
| Deployment target | **macOS 26.0** since 2026-09-15, raised from 14.0 for `SpeechTranscriber`. A side effect worth knowing: no `if #available` guards are needed for the macOS 26 Speech API anywhere |
| **XCTest** | **Unavailable.** Ships with Xcode |
| **swift-testing** | **Available**, and in use. `swift test` fails because SwiftPM looks for Xcode's Platforms directory; driving `swiftc` with `-F`, `-plugin-path` and two `-rpath` flags works. `test.sh` does this and guards the three paths |
| On-device recognition | **en-US only** for locale purposes, which is why the locale is pinned. But **do not read `supportsOnDeviceRecognition` as "recognition will work"** — it reports capability, not model installation, and legacy `SFSpeechRecognizer` on-device is non-functional on macOS 26.6.1 regardless. Check `AssetInventory.status(forModules:)`, the only trustworthy signal, and use the modern `SpeechAnalyzer`/`SpeechTranscriber` API to actually transcribe |
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
10. **The hardened runtime revokes the microphone unless you entitle it.** `--options
    runtime` with no `--entitlements` means no microphone, no prompt, and no row in System
    Settings to turn it back on, because the app never gets far enough to ask. A usage
    string in `Info.plist` is necessary and not sufficient. `build.sh` now asserts the
    entitlement is in the signed bundle. (Corrected 2026-10-19; this entry previously
    claimed a non-interactive session cannot obtain a grant, which was a theory that fit
    the evidence and was false — see item 08.) `ORAL_PROBE_DIRECT=1` borrows the terminal's
    grant and must never touch `Speech`, because merely reading the recognition status is
    privacy-gated and kills the process.
11. **A probe that pumps the run loop cannot be `async`.** `RunLoop.current` is unavailable
    from an async context. `VoiceProbe` is synchronous; `BakeProbe` is async because its
    continuation is driven by the concurrency runtime. (Item 07)
12. **`grep -q` under `set -o pipefail` inverts an assertion.** grep exits on match,
    codesign takes SIGPIPE, and the pipeline reports failure on the success path. Capture
    output, then match. (Item 01)

13. **`@MainActor` on a type propagates to its `static` members.** A `static map()` on a
    `@MainActor` class was main-actor isolated, so calling it from `SFSpeechRecognizer`'s
    authorization callback — which arrives on TCC's XPC queue — tripped Swift 6's executor
    check and killed the process with `SIGTRAP`. Both `map` overloads are now `nonisolated`.
    The symptom was a permission that appeared permanently denied: the process died before
    any status could be stored, so TCC recorded nothing and the status stayed
    `notDetermined` rather than `denied`. **That distinction is the tell** — a real refusal
    persists. `tccutil reset` had nothing to reset. (Item 06)
14. **`supportsOnDeviceRecognition` reports capability, not installation**, and
    `SpeechTranscriber.installedLocales` can claim a locale is installed while
    `AssetInventory.status(forModules:)` says only `.supported` — including for a base
    module configuration with no attribute options. `AssetInventory.status` is the only
    trustworthy signal. Recognition returning nothing with every legacy flag true is what a
    missing model looks like. (Item 10)
15. **Check `~/Library/Logs/DiagnosticReports/` before believing a privacy denial.** The
    crash in trap 13 had been writing `.ips` reports for twelve hours while the failure was
    being read as a refused grant. A probe that prints "DENIED" and a probe that died are
    indistinguishable from stdout.
16. **A probe reporting on its own input is not evidence.** The recorder's level meter was
    believed to be lying for a day. Decoding the file to PCM and measuring RMS directly
    confirmed the meter had been telling the truth all along. Verify a measurement with an
    independent tool before redesigning around it. (Item 08)

17. **The deployment target lives in two places.** Raising it in `build.sh`, `test.sh` and
    `probe.sh` does not touch `LSMinimumSystemVersion` in `Resources/Info.plist`. After the
    macOS 26 migration the plist still said `14.0`, so the app advertised that it ran where
    `SpeechTranscriber` does not exist. Change both, or ship a launch-then-crash. (Items 01
    and 10)
18. **`iconutil -c icns` can exit 0 having dropped sizes.** The only honest check is to
    convert the result back to an iconset and count the PNGs, which `make-icon.sh` does.
    Relatedly, an `.icns` in `Resources/` does nothing without `CFBundleIconFile` in the
    plist — the file is copied and silently ignored. (Item 01)
19. **Command Line Tools 27 broke every `@State`.** The update made the macOS 27 SDK the
   default, where `@State` is a macro whose `SwiftUIMacros` plugin ships only with Xcode:
   "plugin for module 'SwiftUIMacros' not found". `build.sh` now falls back to the 26 SDK the
   same install keeps; `ORAL_SDK` still overrides. (Item 13, 2026-10-25)

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
