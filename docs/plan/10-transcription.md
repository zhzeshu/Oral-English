# 10 — Transcription

**Status:** PARTIAL — 2026-09-14. Code complete and the chunk planning and splicing are
fully tested; **every recognition gate is BLOCKED**, because it needs a speech-recognition
grant and a real recording.
**Changed:** Sources/Core/ChunkPlan.swift, Sources/Services/TranscriberService.swift,
Tests/ChunkPlanTests.swift
**Verified:** ./test.sh (236 tests in 17 suites, including 13 chunk-planning and splicing
rows), ./build.sh clean. The en-US pinning was confirmed by the item 06 probe.
**Blocked:** transcribing anything. No fixtures were captured, so item 11 has nothing to
calibrate against.

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
- [ ] *(BLOCKED: needs a recording and a recognition grant)* The probe transcribes a clearly-read sentence with at most one word differing.
- [ ] *(BLOCKED: needs a recording and a recognition grant)* Per-segment confidence is non-zero and varying, **or** that finding is recorded and the
      fallback signal is wired instead.
- [ ] *(BLOCKED: needs a recording and a recognition grant)* Several real transcripts are saved as fixtures for item 11.
- [ ] *(BLOCKED: needs a recording and a recognition grant)* Recording in the app shows the raw transcript in the expanded row detail.
- [ ] *(BLOCKED: needs a recording and a recognition grant)* Recording with Wi-Fi off still transcribes, proving it is genuinely local.
- [ ] *(BLOCKED: needs a recording and a recognition grant)* A silent recording shows the friendly no-speech message, not a dialog and not a zero.
- [ ] *(BLOCKED: needs a recording and a recognition grant)* A 90-second recording transcribes end to end without truncating.
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
