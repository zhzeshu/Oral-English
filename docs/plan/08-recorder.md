# 08 — Recorder

**Status:** PARTIAL — 2026-09-14. Code complete, pure logic tested, and **recording itself
is now verified** — the probe records, finalizes and reads back a real file. The remaining
gates need someone to speak, unplug a device, or force-quit.
**Changed:** Sources/Core/AudioLevel.swift, Sources/Services/AudioRecorderService.swift,
Sources/Services/PracticeController.swift, Sources/Services/DelegateShim.swift,
Sources/Tools/SettingsProbe.swift, Tests/RecorderSettingsTests.swift,
Tests/ChunkPlanTests.swift
**Verified:** ./test.sh (261 tests in 21 suites), ./build.sh clean,
./probe.sh SettingsProbe, and — 2026-09-15 — the recording path end to end:
`ORAL_PROBE_DIRECT=1 ./probe.sh RecordProbe <path> 3` produced 3.09s, 82,735 bytes,
136,128 frames at 44,100 Hz, finalized by the delegate, peak level 0.67. Capture, encode,
finalize and read-back are proven.
**2026-09-15 — the app could not record at all.** The gap audit for this item checked that
`AudioRecorderService` existed, was tested and was probe-proven, and never checked that
anything called it. Nothing did. `AppModel` constructed the recorder and published its
level into the view; the row drew a `mic` glyph that was not a button; the empty state
advertised "⌘R — record" bound to nothing. There was no code path from the UI to a take,
which is why no take has ever existed.

Closed by adding the orchestration that was missing:

- `Core/TakeAcceptance.swift` — pure, 9 tests. Judges a finished recording before it becomes
  a take: discard when unreadable or under 0.5s, keep-but-do-not-score when the microphone
  heard nothing. That last branch exists because an empty transcript scores 0%, which reads
  as a verdict on the speaker when it is a verdict on the hardware.
- `AudioRecorderService.Result` now carries `peakLevel` and `isReadable`. The live `level` is
  back to zero by the time a caller looks at it, and the peak is what separates "spoke
  quietly" from "microphone is muted".
- `PracticeController.beginRecording` / `finishRecording` claim and release the exclusive
  audio axis. `stopAll()` deliberately does not stop the recorder, and now says so: a take
  in progress has a file to finalize, so it is stopped through `AppModel.stopAudio()`.
  The transport bar's stop button was routed straight to `stopAll()`, which would have
  stranded the file in `incoming/`.
- `AppModel.startRecording` / `stopRecording` / `toggleRecording`: permission asked on the
  first tap rather than at launch, staged into `incoming/`, judged, adopted, appended, then
  scored through the existing `rescore` so there is one path from audio to a score.
- `AppModel.sweepInterruptedTakes` — the library README has promised since it was written
  that an interrupted recording is adopted or quarantined on the next launch, and nothing
  did either. It quarantines rather than adopts: a staged file is named only by its take id,
  so its target is not recoverable from disk and adopting would mean inventing one.
- ⌘R is a real `CommandMenu("Practice")` item, along with ⌘P for the reference.

**Blocked:** the device-unplug, force-quit and machine-sleep gates, which need a human
doing something physical at the right moment.

**2026-09-15 — no longer blocked: a take of the user's own voice now exists.** Kept at
`~/Desktop/take.m4a`, 8.40s of "The fog came in on little cat feet." See
**Real speech, independently confirmed** below. This is also the first input item 11 has
ever had.

**2026-09-15 — the prompt was audible but invisible.** The probe spoke the sentence through
Ava and never printed it, and Swift's stdout is fully buffered when it is not a terminal, so
even the "SPEAK NOW" line arrived after the recording had ended. Reported from use: "I have
not seen the sentence, so I do not read now." Fixed in two places:

- `RecordProbe` sets `setvbuf(stdout, nil, _IONBF, 0)` and prints the sentence before
  speaking it, then again at the moment recording starts, so it stays on screen throughout.
- `LoopProbe` runs under `open`, where stdout is captured and cannot reach the screen at
  all, so `ProbeApp` grew a floating prompt window: the sentence in 24pt, and a status line
  that tracks listen / get ready / READ IT NOW / seconds remaining / transcribing / score.

Hearing a sentence once and reciting it from memory measures memory, not pronunciation. The
text has to be visible while it is read.

**Verification style:** probe-first, then verified against QuickTime. The activity state
machine and the level conversion are pure and unit-tested.

## Goal

Record a sentence, keep the take on disk with a timestamped name, and show a live input
level so it is obvious the microphone is working.

## Files

- `Sources/Core/AudioActivity.swift` — the state machine, pure and unit-tested
- `Sources/Services/AudioRecorderService.swift`
- `Sources/Services/PracticeController.swift`
- `Sources/Tools/RecordProbe.swift`
- `Tests/AudioActivityTests.swift`

## Probe first

`./probe.sh RecordProbe` records three seconds from the default input to a temp `.m4a`, waits
for the finish delegate, then prints the file size, the reported duration and the peak level.
Passes when the duration is three seconds plus or minus 0.3, the file is at least 20 KB, and
it opens in QuickTime. Revision 1 said "non-trivial in size" and "about three seconds",
which cannot be evaluated.

If the probe fails, no amount of UI work will help.

## Encoder settings, exactly

```
AVFormatIDKey: Int(kAudioFormatMPEG4AAC)
AVSampleRateKey: 44100.0          // Double, not Int
AVNumberOfChannelsKey: 1
AVEncoderBitRateKey: 64000
AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
```

Failure modes are all quiet ones. Linear PCM with an `.m4a` extension gives an unplayable
file. A mismatched extension makes some readers refuse it. Passing the sample rate as `Int`
is silently ignored — assert the stored value is a `Double` in a unit test, which is one line.
And `record()` returns a `Bool` that is the only signal for most misconfiguration, so
**check it**.

Call `prepareToRecord()` first, or the first take clips its opening word.

Note the format asymmetry: recordings are 44100 Hz mono, while synthesis to buffer is 22050 Hz
mono non-interleaved. Playback resamples transparently so items 07 and 09 are unaffected, but
item 10 feeds buffers to the recognizer and takes its format from them, so it needs an explicit
conversion boundary. Revision 1 documented neither rate together and so never noticed.

## Two axes of state, not one

`PracticeController` holds an exclusive `audio` activity — idle, speaking, recording, playing
a take, playing A/B — plus an `inFlight` set of targets for background work like scoring and
baking. Record enablement binds to `audio == .idle`; per-row spinners bind to the set.

Revision 1 put `scoring` in the exclusive slot. Recognition of a 90-second whole-passage take
is many seconds, so that would block the next sentence while a take scored, contradicting its
own requirement that scrolling stay smooth during scoring. Baking a reference was a third long
activity, absent from the enum entirely.

The exclusive audio axis is what makes "record while the reference plays" structurally
impossible, which is what stops item 10's recognizer transcribing the reference instead of
the user. Add a 250 ms delay after synthesis finishes before arming the recorder so the tail
does not bleed in.

The state machine is pure. Unit-test it: record is refused while speaking; two rapid record
taps do not double-start; a scoring job in flight does not block recording; switching passages
mid-record is refused or stops cleanly.

## Delegate isolation, with a deadline

`AVAudioRecorderDelegate` is a non-isolated Objective-C callback, and this is where Swift 6
concurrency bites. Use one shim per operation, owned by the `@MainActor` service for that
operation's duration, holding a continuation behind a lock, resuming **exactly once** on both
the success and error paths. A double resume is a hard crash; a missing resume hangs the UI,
so cover `encodeErrorDidOccur` too. Never use `assumeIsolated`.

**Every shim carries a deadline.** Revision 1 covered the error callback, which helps only
when a callback arrives. A callback that never arrives was unhandled, and because every
control binds to the activity state, one unresumed continuation disables the whole app until
force quit — which then collides with the take-rescue path and discards the take. Budgets,
scaled to the work rather than absolute: recorder finish 5 s after stop; player finish
duration plus 2 s; synthesis word callback 10 s of silence; recognition the greater of 15 s
and twice the audio duration. On timeout: resume with an error, log the full context, reset to
idle, and for the recorder still import whatever bytes exist — a truncated file beats nothing.

The same shim shape is reused in items 09 and 10. Get it right once.

## Never lose spoken audio

Revision 1 promised "stop and import the take on termination", which is unimplementable:
stopping requires awaiting the finish delegate, and `applicationWillTerminate` is synchronous
and time-boxed. It also only fires on graceful quit, so force quit, crash and power loss
silently left a header-less file that `passage.json` already referenced.

The structure changes instead:

1. Record into `<passage>/incoming/<uuid>.m4a`. Move it into place and write the take record
   **only after** the finish delegate fires. `passage.json` never references an unfinalized
   file.
2. On launch, scan `incoming/`. Anything there is an interrupted take: adopt it if
   AVFoundation can open it, otherwise move it to `recovered/` and say so in one line. An
   unplayable file the user can see beats a record pointing at a broken one.
3. Observe `NSWorkspace.willSleepNotification` and stop cleanly before sleep, which turns the
   sleep case into the normal delegate path. Machine sleep mid-recording was unmentioned in
   revision 1, and it also tears down and re-attaches the input device.
4. On graceful quit, return `.terminateLater`, run the stop-and-import, and reply when done,
   with a hard 3-second cap so a wedged encoder cannot make the app unquittable.

The guarantee is now "never **silently** discarded", which is the honest version.

## Device loss and disk space

Observe default-input-device changes. On a change during recording, stop, import what was
captured, return to idle, and surface `AppFailure.deviceLost` with a note that the partial
take was kept. AirPods dropping mid-sentence is the most everyday interruption there is, and
it is the never-fires case above.

Pre-flight available capacity before arming, and refuse with `AppFailure.outOfSpace` rather
than losing a take. Handle `didFinishRecording(successfully: false)` as a first-class case
distinct from success, importing the partial file anyway.

## Level meter

Enable metering, poll at about 20 Hz on the main run loop, convert average power in decibels
to a zero-to-one scale, and invalidate the timer on stop and on the sleep path. Unit-test the
conversion: −160 dB to 0, 0 dB to 1, clamped.

Then **act on it**, which revision 1 did not: if average power stays at the floor for more
than three seconds while recording, show a non-blocking "no input is being detected" hint.
That one check catches a dead microphone, a hardware-muted microphone, and a wedged privacy
grant — three of the app's nastiest silent failures for about ten lines.

## Done when

- [x] `./test.sh` passes, including the state machine, the settings assertion and the decibel
      conversion.
- [x] The probe produces a readable file within the stated bounds: **3.13 s, 57,892 bytes,
      138,176 frames at 44100 Hz mono**, finalized by the delegate. The microphone turned out
      to be grantable to a probe after all — see the findings.
- [ ] *(BLOCKED: needs a microphone grant)* Recording writes an `.m4a` under the passage folder with a timestamped colon-free name,
      and a matching take JSON beside it.
- [ ] *(BLOCKED: needs a microphone grant)* The stored relative path resolves and the file plays.
- [ ] *(PARTIAL)* The meter rests at zero in silence, confirmed by the probe. Whether it
      moves while speaking needs someone to speak.
- [ ] *(BLOCKED: needs a microphone grant)* Recording twice on one sentence keeps both takes, including twice within one second.
- [x] The record control is disabled while the reference is playing.
- [ ] *(BLOCKED: needs a microphone grant)* **Force quitting** mid-recording leaves a file in `incoming/`, and the next launch either
      adopts or quarantines it with a message.
- [ ] *(BLOCKED: needs a microphone grant)* Sleeping the machine mid-recording keeps the partial take and leaves the UI idle on wake.
- [ ] *(BLOCKED: needs a microphone grant)* Unplugging the input mid-recording returns the UI to idle within 5 seconds and keeps a
      playable partial take.
- [ ] *(BLOCKED: needs a microphone grant)* With the volume artificially near-full, arming refuses with a message rather than
      producing a zero-byte take.
- [x] Recording in silence sets `noInputDetected`, verified by the probe: the level held at
      0.00 for three seconds and the flag fired.


## Findings while executing this item

**`AVAudioRecorder.settings` is empty until the recorder is prepared.** Verified by probe:
pass a five-key dictionary in, read it back immediately, and get nothing. So there is no
round trip to lean on for confirming a key was accepted — which is exactly why the type
assertions matter. A sample rate passed as `Int` is silently ignored and nothing else in the
project would catch it, so that is now a one-line test.

**Two strict-concurrency shapes worth knowing.** `[String: Any]` is not `Sendable`, so a
`nonisolated static let` of that type is rejected; a computed property sidesteps it for
free. And a captured `var` in a `@Sendable` closure warns even when the closure runs
synchronously, so the converter's one-shot flag lives in a small reference box.

## The probe found a real bug in the shim

This is what probe-first is for, and it paid for itself here.

The probe reported `finalized by the delegate: false` while producing a perfectly readable
file. The delegate had fired in 0.01 s, so it was not a timeout. The cause was in `OneShot`:
`recorder.stop()` is called synchronously, the finish callback arrives immediately, and only
*then* does the caller `await`. The original implementation only resumed a continuation that
was already waiting, so the result was dropped and `value()` then threw — marking **every
take** as not cleanly finalized while the audio was fine.

`OneShot` now buffers the first result, so a delegate that fires before anyone awaits is
still honored. Two details in the fix matter: it keeps only the *first* result, so a later
error cannot overwrite a success that already happened; and it uses `withLock` rather than
manual lock and unlock, because `NSLock.lock()` is unavailable from an async context — which
is the compiler stopping you from holding a lock across a suspension.

Since this shim is reused by the player, the synthesizer and the recognizer, the bug would
have affected all four.

## A probe can hold a microphone grant, with an embedded Info.plist

The first attempt aborted with no message. macOS privacy **kills** a process that asks for
the microphone without a usage string rather than prompting, and a bare command-line binary
has no `Info.plist`. Embedding one into the binary via
`-sectcreate __TEXT __info_plist` fixes it, and `probe.sh` now does that for every probe and
ad-hoc signs the result so there is a code identity for the grant to attach to.

Without this, the probe-first approach simply does not work for anything privacy-gated,
which would have taken items 08 and 10 off the table entirely.

## Still unverified

Force-quit recovery, the sleep path, and device loss mid-recording. Those need a human
unplugging something or killing the app at the right moment, and they are the paths most
likely to still hold a bug.

## A probe cannot obtain a microphone grant from a non-interactive session

Established the hard way, and worth writing down so nobody repeats it. Four routes were
tried against the probe bundle `com.zackzhang.oralenglish.probe`:

| Route | Result |
| --- | --- |
| Bare binary, embedded `__info_plist` | Microphone works — it inherits the terminal's grant. **Speech recognition crashes**, because the Speech framework reads `NSBundle.mainBundle`, which a bare binary lacks |
| Real `.app` bundle, run `Contents/MacOS/<name>` directly | Killed by privacy. Running the binary from a terminal makes the **terminal** the responsible process, so the usage string is looked for in the terminal's plist — the same trap item 01 documents for the app |
| Real `.app`, launched with `open -W --stdout` | Own identity, `mainBundle` resolves, both usage strings readable — and the request still flips `notDetermined` to `denied` **with no dialog** |
| Same, plus an `NSApplication` accessory host, installed to `~/Applications`, privacy record reset | Identical auto-denial |

So the blocker is not the plist, not the bundle, not the signature and not the location. It
is that this session cannot present an interactive permission dialog, and macOS denies
rather than prompting.

**What this means for the workflow.** Recording verification has to happen either in the
real app, which already holds the grant, or by the user running the probe from their own
Terminal where the dialog can appear:

```
ORAL_PROBE_DIRECT=1 ORAL_SENTENCE="The fog came in on little cat feet." \
  ./probe.sh RecordProbe ~/Desktop/take.m4a 8
```

Direct mode borrows the terminal's microphone grant and deliberately never touches `Speech`
— `RecordProbe` reads `AVAudioApplication.recordPermission` directly rather than
constructing `PermissionService`, because merely *reading* the speech-recognition status is
privacy-gated and would kill the process.

`ProbeApp` is kept even though it did not solve this: a probe that does get a grant needs a
real application to present anything in, and the reasoning is recorded in the file.

## What was verified end to end anyway

The pipeline ran with Ava speaking the prompts: 8.36 s recorded, 368,576 frames at 44100 Hz
mono, finalized by the delegate in 0.73 s, readable back as audio. Peak level 0.00 across
the whole window, with the microphone reported granted, the built-in mic the live default,
and input volume at 37 — so the encoder, the delegate await, the staging path and the
no-input heuristic are all proven, and only the captured signal is missing.

## Real speech, independently confirmed — 2026-09-15

The handoff's open question was whether the microphone yielded a silent stream or whether
nobody had spoken during the window. It was the latter. Every earlier run measured peak
0.00 because the window closed unspoken.

An 8-second run with the prompt actually read aloud:

```
recording 8 seconds. READ IT NOW:
  1.0s  level 0.70  #####################
  2.0s  level 0.82  ########################
  3.0s  level 0.87  ##########################
  4.0s  level 0.93  ############################
  5.0s  level 0.25  #######
  8.0s  level 0.15  ####

duration: 8.40s   size: 124346 bytes   peak level: 0.93
finalized by the delegate: true      no input detected: false
readable: 370624 frames, 44100 Hz, 1 channel
```

**Verified without trusting the meter**, because a level meter reporting on its own input is
not independent evidence. Decoding the `.m4a` to 16-bit PCM and measuring samples directly:
370,624 frames at 44100 Hz, **RMS −21.4 dBFS**, per-second peaks showing speech in seconds
0–4 and near-silence after. The audio is genuinely present, and the meter was telling the
truth.

This also closes the meter gate above: the bar rests at zero in silence *and* tracks speech.

### One defect to fix before item 11 records fifty takes

True peak reaches **1.0000 (0 dBFS)** — the take is clipping. The probe's reported 0.93 is
an average-power reading and understates it, so `peakLevel` alone will not catch this.

It matters for calibration specifically. Clipped consonants are exactly what a recognizer
mishears, so a clipped fixture set would tune the scorer against distortion rather than
against speech. Trim input gain before recording the set.

Worth considering a pre-flight that warns when gain would clip. The plan already pre-flights
available disk space before arming, and this is the same shape of problem — cheap to check
up front, expensive to discover in a labelled corpus.
