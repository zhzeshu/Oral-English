# 10 — Transcription

**Status:** PARTIAL — migrated 2026-09-15. `TranscriberService` now runs on
`SpeechAnalyzer`/`SpeechTranscriber`; the deployment target was raised to macOS 26.0 and
**no legacy fallback was kept**. Transcription, per-word confidence and per-word timing all
work end to end, and the scorer produces a real word diff from real speech for the first
time. The confidence question this item was blocking on is **answered, positively**.

Remaining gates are in-app behaviours that need a human using the app, plus item 11's
corpus. The architecture decision is closed — see **The migration, 2026-09-15** below.
**Changed:** Sources/Core/ChunkPlan.swift, Sources/Services/TranscriberService.swift,
Tests/ChunkPlanTests.swift
**Verified:** ./test.sh (236 tests in 17 suites, including 13 chunk-planning and splicing
rows), ./build.sh clean. The en-US pinning was confirmed by the item 06 probe.
**No longer blocked:** the recognition grant (obtained and persisted), a real recording
(`~/Desktop/take.m4a`), and the confidence question. All three were settled on 2026-09-15.

**Decision taken 2026-09-15: migrated.** Deployment target raised from macOS 14.0 to 26.0,
legacy path removed rather than kept as a fallback, because a fallback would be untested
code that is known-broken exactly where it would run.

To run it: `./probe.sh RecordProbe` to capture audio, then
`./probe.sh TranscribeProbe <file> "the reference text"`.

**Verification style:** probe-first. Show the raw transcript and nothing else. The chunk
planning is pure and unit-tested.

## Goal

Turn a recorded take into a transcript with per-word timing and confidence, entirely on this
machine. No scoring in this item.

## Why scoring is not here

Displaying the raw transcript first proves the pipeline before calibration. Doing both at once
means a bad score could be a recognition problem or an alignment problem with no way to tell.
The scorer already exists from item 03; item 11 calibrates it against what this item produces.

## Files

- `Sources/Core/ChunkPlan.swift` — pure planning and timestamp splicing, unit-tested
- `Sources/Services/TranscriberService.swift`
- `Sources/Tools/TranscribeProbe.swift`
- `Sources/Views/TakeDetailView.swift`
- `Tests/ChunkPlanTests.swift`

## Probe first

`./probe.sh TranscribeProbe <file>` forces on-device recognition and prints the transcript with
each segment's confidence and timing. Passes when a clearly-read sentence comes back with at
most one word differing.

Run it on takes from item 08 and **save the output** as fixtures. Item 11 is calibrated against
them. You should already have three to five from before item 03; add more here.

**Assert that confidence is non-zero and varying.** `SFTranscriptionSegment.confidence` is
commonly 0.0 for on-device results. If it is uniformly zero, item 03's hard-to-hear constraint
rests on a constant and the app would never show a score again — so record that fact and switch
to the metering-plus-missed-word-ratio fallback item 03 specifies. Revision 1's checklist never
asserted this.

## Red — chunk planning is pure

Extract the planning and splicing from the I/O so it is testable: given a duration and a list
of low-energy points, produce chunk ranges; given per-chunk transcripts with start offsets,
produce one transcript with corrected timings.

| Test | Assertion |
| --- | --- |
| 30-second audio | one chunk, no splitting |
| 90-second audio | multiple chunks, each at or under 45 seconds |
| splicing | segment timings increase monotonically across chunk boundaries |
| splicing | each chunk's segments are offset by that chunk's start |
| a boundary with no quiet point | still produces a valid plan rather than looping |
| empty transcript from one chunk | the others still splice |

Revision 1 designed chunking at this item and first exercised it at item 12, verified only by a
human reading a list of numbers for monotonicity. The plan itself warned that without the offset
"the timings silently become useless".

## Green

`TranscriberService` is the only file that knows `Speech` exists. Force
`requiresOnDeviceRecognition`, since local-only was a requirement, and set `addsPunctuation`
off, because punctuation is noise for word comparison.

**Pin the locale to en-US explicitly.** Verified: `en-GB` and `zh-CN` report available but
**not** on-device, and the never-fall-back rule then leaves such a user with no scoring at all.
This is an American English trainer, so the locale is a product decision, not a system setting.
Revision 1 never said which locale the recognizer was built with. Keep the runtime check for the
asset-not-yet-downloaded case and name en-US in that message so the user knows what to fetch.
Constructing recognizers for other locales writes asset warnings to the system log, so do not
enumerate them for the picker.

Sentence-length clips can use a URL request. Paragraph and whole-passage audio must use buffer
feeding, because a single request has historically capped near a minute and a whole passage
easily runs to 90 seconds.

**Convert the format explicitly.** Read with `AVAudioFile` and convert through `AVAudioConverter`
to the recognizer's native format, asserting the format matches before the first append.
Recordings are 44100 Hz interleaved-from-file; synthesis gives 22050 Hz non-interleaved; the
recognizer takes its format from the buffers. A mismatch produces gibberish that the scorer then
reports as terrible pronunciation, which is a wrong score the user would trust.

## Sendability

`SFSpeechRecognitionResult` and `SFTranscriptionSegment` are not `Sendable`. Map them into the
`Transcript` value type from item 02 **inside** the completion closure, before resuming the
continuation. Applied mechanically, that one rule eliminates the entire class of Swift 6 errors
here.

## Error cases that must not look like failures

| Error | Presentation |
| --- | --- |
| `kAFAssistantErrorDomain` 1110, no speech detected | "I could not hear anything, try again" with a re-record button. **Never** a dialog and **never** a zero score |
| Offline model unavailable for en-US | Explain that scoring needs the offline model. Never silently use the server |
| Audio file missing or unreadable | The item 09 missing-audio presentation, not a raw error |
| Recognition timed out | The item 08 deadline path: log, reset to idle, offer retry |
| Not authorized | Defer to item 06 |

Cancel in-flight recognition when its passage is deleted or its text edited. Each job carries
its target, passage id and a passage revision; before writing a score, reload and drop the
result if the passage is gone or the revision moved. Trashing relocates the file under a running
recognizer, which revision 1's error table did not cover.

## Done when

- [x] `./test.sh` passes, including every chunk-planning row.
- [~] *(PARTIAL)* The modern-API probe transcribes a real recording, but **not yet within
      one word**: "The fog came in on little cat feet." came back as
      "Oh, came in on a little cat feet." — "The fog" lost, "a" inserted. Two errors, so
      this gate is **not** met. The take clips at 0 dBFS (item 08), which is a plausible
      cause, so re-test on a clean take before concluding the recognizer is at fault.
- [x] **Per-word confidence is non-zero and varying** — settled 2026-09-15, via the modern
      API. mean 0.7776, 8 distinct values, min 0.194, max 0.986. Item 03's hard-to-hear rule
      can be used as designed and **the fallback is not needed**. Requires
      `attributeOptions: [.transcriptionConfidence]`; without it no confidence is reported
      at all.
- [ ] *(BLOCKED: needs a recording and a recognition grant)* Several real transcripts are saved as fixtures for item 11.
- [ ] *(BLOCKED: needs a recording and a recognition grant)* Recording in the app shows the raw transcript in the expanded row detail.
- [ ] *(BLOCKED: needs a recording and a recognition grant)* Recording with Wi-Fi off still transcribes, proving it is genuinely local.
- [ ] *(BLOCKED: needs a recording and a recognition grant)* A silent recording shows the friendly no-speech message, not a dialog and not a zero.
- [x] **A 90-second recording transcribes end to end without truncating** — verified
      2026-09-15. A 92.45s file returned 87 words (eleven full repetitions of the source
      sentence, so complete coverage), 0.52s, timings monotonic across the whole transcript.
      Done in a **single** `analyzeSequence` pass with no chunking.
- [ ] *(BLOCKED: needs a recording and a recognition grant)* Deleting a passage mid-transcription neither crashes nor writes an orphaned score.


## The confidence question is still open, and item 03 depends on it

Item 03's hard-to-hear rule turns on mean recognizer confidence, and
`SFTranscriptionSegment.confidence` is commonly reported as **0.0** for on-device results.
If that is true on this machine, every take trips the hard-to-hear presentation and the app
never shows a score again.

The probe that would settle it needs a recording and a grant, so **this is the single most
important thing to check first** once permissions are granted. If confidence is uniformly
zero, item 03 already specifies the fallback: derive the signal from the recorder's own
metering plus the missed-word ratio, both of which are already available and independent of
Speech.

## What is tested, and what that buys

The chunk planning and the timestamp splicing are pure and fully covered: contiguous
coverage at four durations, a quiet point preferred over the hard limit, termination on
awkward inputs, out-of-order pieces, an empty chunk mid-sequence, and monotonic timings
across four boundaries. That last one is the bug the plan feared most — every chunk's
timings restarting at zero — and it is now a unit test rather than a human reading numbers.

What is not tested is everything touching `Speech`: whether a request really caps near a
minute, whether the format conversion feeds the recognizer correctly, and whether the error
mapping catches the codes that actually occur.

## What 2026-09-15 established

Three layers of cause, each hiding the next. Worth reading in order, because stopping at any
one of them gives a wrong conclusion.

### 1. A crash, not a denied permission

`PermissionService.requestRecognition()` died with `SIGTRAP` on every call, inside TCC's
reply callback — a `@MainActor` type propagating isolation to a `static map()` invoked on
TCC's queue. Full write-up in item 06. Until this was fixed, nothing could even ask for the
grant, and the failure presented as "DENIED".

### 2. The en-US on-device model was never installed

This is the part the legacy API actively misreports. All of these were true **while
recognition returned nothing**:

| Signal | Value |
| --- | --- |
| `SFSpeechRecognizer.isAvailable` | `true` |
| `SFSpeechRecognizer.supportsOnDeviceRecognition` | `true` |
| `SpeechTranscriber.installedLocales` contains en-US | `true` (9 English locales listed) |
| `AssetInventory.status(forModules:)` for en-US | **`.supported`, not `.installed`** |

`supportsOnDeviceRecognition` reports *capability*, not *installation*. And
`installedLocales` disagrees with `AssetInventory.status` — including for the **base**
module configuration with no attribute options, so this is not a
confidence-assets-only effect. Treat `AssetInventory.status` as the only trustworthy signal,
and never gate behaviour on `supportsOnDeviceRecognition` alone.

Installing via `AssetInventory.assetInstallationRequest(supporting:).downloadAndInstall()`
made the modern API transcribe immediately.

### 3. Legacy on-device recognition is dead on this OS

The decisive test, both run in the same session against the same file, **after** the asset
was installed:

| API | Result |
| --- | --- |
| `SFSpeechRecognizer` + `SFSpeechURLRecognitionRequest` | `""` — empty, 0 segments, 0.26s, **no error**, `isFinal` true |
| `SpeechAnalyzer` + `SpeechTranscriber` | `"Oh, came in on a little cat feet."` with per-word confidence |

Also ruled out: container format. Legacy returns empty for both the 44100 Hz AAC `.m4a` and
a 16-bit PCM WAV conversion of identical audio, so the format-conversion boundary this item
worried about is **not** the cause.

An instant final result with no error and no segments is the signature. There is no legacy
code path worth keeping on this machine.

### The confidence answer, in full

```
Oh,     conf 0.1940      <- misheard ("The fog")
came    conf 0.4410      <- misheard boundary
in      conf 0.9610
on      conf 0.9860
a       conf 0.9850      <- inserted
little  conf 0.9570
cat     conf 0.9480
feet.   conf 0.7490

mean 0.7776, distinct 8, min 0.1940, max 0.9860
```

Better than item 03 assumed: **confidence correlates with correctness**. The two
misrecognised words scored 0.19 and 0.44 while every correctly-heard word exceeded 0.94.
That makes confidence useful not only for the hard-to-hear gate but potentially as a
per-word signal in the score itself — worth considering in item 11, though not yet
measured across more than one take.

## The decision this item now needs

Rewriting `TranscriberService` on `SpeechAnalyzer`/`SpeechTranscriber` means raising the
deployment target from macOS 14.0 to 26.0, which edits the overview's Verified-environment
table and changes availability enforcement across `Sources/`.

Arguments for not keeping a legacy fallback, having measured it: the legacy path does not
work on the only machine this app runs on, so a fallback would be untested code that is
known-broken where it would actually run. Gemini was consulted and argued the same, on the
weaker ground that it would merely be dead code.

What the migration would touch:

- `Sources/Services/TranscriberService.swift` — the whole recognition path.
- Chunking: `SpeechAnalyzer.analyzeSequence(from: AVAudioFile)` is a one-shot file API, so
  the 40-second `singleRequestLimit` and the manual chunk/splice machinery may become
  unnecessary. **Do not delete `ChunkPlan` on that assumption** — its 13 tests are the only
  coverage of monotonic timings across boundaries, and buffer feeding is still needed for
  live recognition. Confirm against a 90-second take first.
- The format conversion boundary — `availableCompatibleAudioFormats` on `SpeechTranscriber`
  replaces guessing the recognizer's native format.
- Asset installation needs a real place in the app: a first-run check on
  `AssetInventory.status` with a visible download, since the model is a few hundred MB and
  cannot be assumed present. This is a new user-facing state the plan does not currently
  describe.

## Probes added for this

- `./probe.sh AssetProbe` — legacy flags, modern availability, installed locales, and
  `AssetInventory.status` side by side. Run this first whenever recognition returns nothing.
- `./probe.sh ModernTranscribeProbe <file> ["reference"]` — transcribes through the modern
  API in two passes, base options then `.transcriptionConfidence`, and reports the
  confidence distribution. Asset installation is opt-in behind `ORAL_INSTALL_ASSETS=1`,
  because a few-hundred-megabyte download is the user's call and not a probe's.

`TranscribeProbe` had a diagnostic bug of its own: it reported an empty transcript as
`ALL ZERO confidence -> switch to the fallback`. Mean confidence is 0 over zero words by
arithmetic, which says nothing about what the recognizer reports for words it finds. That
false verdict nearly caused item 03's hard-to-hear rule to be rewritten for no reason. It
now distinguishes the two cases and points at the modern probe.

## The migration, 2026-09-15

`TranscriberService` was rewritten on `SpeechAnalyzer` + `SpeechTranscriber`. The public
API is unchanged — `transcribe(fileURL:) async throws -> Transcript` — so no caller moved.

**Deployment target raised to macOS 26.0** in `build.sh`, `test.sh` and `probe.sh`. Done as
a separate step and verified green before the service was touched, so a target failure and a
migration failure could not be confused. A useful side effect: `SpeechTranscriber` needs
macOS 26, so with the target raised there are **no `if #available` guards anywhere** in the
new code.

**No legacy fallback.** Not because it would be dead code, but because it is known-broken on
the only machine this app runs on. Shipping a fallback that fails exactly where it would
execute is worse than not having one.

### What the result looks like

The full pipeline, from the take recorded in item 08:

```
Oh,     conf 0.194  at 0.00s for 1.20s
 came   conf 0.441  at 1.20s for 0.54s
 in     conf 0.961  at 1.74s for 0.54s
 on     conf 0.986  at 2.28s for 0.48s
 a      conf 0.985  at 2.76s for 0.30s
 little conf 0.957  at 3.06s for 0.24s
 cat    conf 0.948  at 3.30s for 0.72s
 feet.  conf 0.749  at 4.02s for 0.72s

mean confidence 0.677    timings monotonic: yes
scored: accuracy 69 percent, verdict clear
  6 matched, 0 close, 1 wrong, 1 missed, 1 extra
  words to work on: The, fog
```

Worth noting what that last line demonstrates: the scorer independently flagged "The" and
"fog", which are exactly the two lowest-confidence words. The verdict is `clear` rather
than `hardToHear`, so the item 03 rule behaved correctly on real speech instead of
defaulting to the failure presentation.

### Decisions inside the rewrite

**`attributeOptions: [.transcriptionConfidence, .audioTimeRange]` is load-bearing.** Without
the first, results carry **no confidence at all** — measured: the same audio gave one run
with no confidence attribute under base options, and eight runs each carrying confidence
once it was requested. The second is what supplies per-word timing.

**Results are consumed concurrently with analysis.** Draining `transcriber.results` after
`analyzeSequence` deadlocks — the analyzer does not finish until results are taken.

**An empty transcript now throws `AppFailure.noSpeechDetected`.** The legacy path returned
an empty `Transcript`, which the scorer turned into 0% `hardToHear`. The plan was explicit
that a silent take must never be a zero score, because a zero reads as a verdict on the
speaker when it is a verdict on the audio.

**The deadline is kept**, as a watchdog that calls `analyzer.cancelAndFinishNow()` rather
than abandoning the call, so the results stream terminates and the collector completes. Same
reasoning as the delegate shims: every control binds to the activity state, so an operation
that never returns disables the app until force quit.

**Asset installation is never implicit.** `transcribe` throws
`offlineModelUnavailable` when the model is absent; `installModel()` is separate and
explicit. A few-hundred-megabyte download is not something a scoring call should start
behind the user's back.

### A bug the migration exposed

`PermissionService.offlineModelAvailable` was computed from
`SFSpeechRecognizer.supportsOnDeviceRecognition`, and that flag was measured returning
`true` while no model was installed and nothing could transcribe. It feeds `canScore` and
the missing-model banner, so **the app would have promised scoring and then failed at score
time**.

It now comes from `AssetInventory.status` via
`PermissionService.refreshModelAvailability()`. That had to be a separate async method
because `refresh()` is synchronous and `AssetInventory.status` is not; `AppModel` calls it at
launch and after wake, since a model can be removed or a download can finish while asleep.

Related: the `.offlineModelMissing` banner offered "Open settings" and opened the Speech
Recognition privacy pane, where there is nothing to fix — a missing model is not a denied
permission. The button is now "Download model" and calls `AppModel.installSpeechModel()`.

### ChunkPlan is now unused in production — and that is a decision, not a cleanup

The 92-second test settles the question this item flagged: `analyzeSequence` handled the
whole file in one pass with complete coverage and monotonic timings, so **the 40-second
`singleRequestLimit` and the manual chunk/splice machinery are not needed for file
transcription.**

`ChunkPlan` is deliberately **not deleted**. It is now referenced only by its own file, its
13 tests, and `TranscribeProbe`'s display. Before removing it, consider that its tests are
the only coverage of monotonic timings across chunk boundaries, and that live recognition
while recording is not built yet — `SpeechAnalyzer` takes an `inputSequence` for streaming,
which would probably make it unnecessary there too, but that is unverified. Deleting a Core
type and 13 tests on an assumption is how the coverage gap in item 06 happened.
