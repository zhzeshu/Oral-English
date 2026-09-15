# 08 — Recorder

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

- [ ] `./test.sh` passes, including the state machine, the settings assertion and the decibel
      conversion.
- [ ] The probe produces a file that plays in QuickTime, within the stated bounds.
- [ ] Recording writes an `.m4a` under the passage folder with a timestamped colon-free name,
      and a matching take JSON beside it.
- [ ] The stored relative path resolves and the file plays.
- [ ] The level meter moves while speaking and rests near zero in silence.
- [ ] Recording twice on one sentence keeps both takes, including twice within one second.
- [ ] The record control is disabled while the reference is playing.
- [ ] **Force quitting** mid-recording leaves a file in `incoming/`, and the next launch either
      adopts or quarantines it with a message.
- [ ] Sleeping the machine mid-recording keeps the partial take and leaves the UI idle on wake.
- [ ] Unplugging the input mid-recording returns the UI to idle within 5 seconds and keeps a
      playable partial take.
- [ ] With the volume artificially near-full, arming refuses with a message rather than
      producing a zero-byte take.
- [ ] Recording in silence shows the no-input hint.
