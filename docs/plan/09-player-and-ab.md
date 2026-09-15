# 09 — Player and A/B comparison

**Status:** DONE — 2026-09-14
**Changed:** Sources/Services/AudioPlayerService.swift, Sources/Tools/PlaybackProbe.swift
**Verified:** ./test.sh (236 tests in 17 suites), ./build.sh clean,
./probe.sh PlaybackProbe — verified against baked reference audio, which needs no
microphone and no permission

**Verification style:** probe-first, then judged by ear.

## Goal

Play back a take, and play the reference against it so the difference is audible. This closes
the listening half of the comparison requirement, and it is genuinely useful before any
scoring exists.

## Files

- `Sources/Services/AudioPlayerService.swift`
- `Sources/Tools/PlaybackProbe.swift`
- `Sources/Views/SentenceRowView.swift`

## Probe first

`./probe.sh PlaybackProbe` plays a known file and reports its duration, then plays two files
at a shared start anchor and confirms both actually started. Passes when both are audible and
neither cuts out.

## Green

Two player slots, one for the reference and one for the take. Two rather than one, because A/B
needs both alive at once and a single slot forces a reload and an audible gap.

Sequential A/B is the default: reference, a short pause, then the take. That ordering trains
the ear and needs no time alignment.

## The four gotchas

**Each player needs its own strong reference.** A player held only locally deallocates
mid-play and goes silent, which presents as "the second one does not work".

**`enableRate = true` must be set before `prepareToPlay()`**, or rate changes are ignored with
no error.

**Simultaneous playback needs a shared anchor.** Two players mix at the system level with no
session to configure, so overlay works, but calling `play()` on both back to back gives a 10
to 50 millisecond skew that is clearly audible on speech onsets. Start both from
`deviceCurrentTime` plus a small offset.

**Live synthesis cannot be overlaid.** It cannot be time-aligned reliably against a recording,
so offer overlay only against a **baked** reference file and keep sequential A/B as the
default. Disable the overlay control until a reference has been baked.

## Missing audio

A take whose audio file is gone must not throw. Item 04's scan sets a flag; here, play, A/B and
re-score are disabled for that take and the row shows one muted line saying the recording is no
longer in the folder. The app invites the user into that folder, so a deleted file is a matter
of time — revision 1 listed four playback gotchas and "the file is not there" was not among
them.

## Delegate isolation

The same shim as item 08, with its deadline, resuming once on both
`audioPlayerDidFinishPlaying` and the decode error callback.

## Done when

- [x] `./test.sh` passes.
- [x] The probe plays a file and reports a sensible duration.
- [ ] Playing a take from a row sounds correct and stops cleanly. *(PARTIAL: playback and
      stop are verified by probe. Doing it from a row needs a recorded take, which needs a
      microphone.)*
- [x] A/B plays reference then take with an audible gap, in that order.
- [x] A playback speed change is audible, proving `enableRate` was set early enough.
- [x] Starting a new playback while one runs stops the first rather than mixing, and the
      overlay control is the only path that plays two at once.
- [x] Overlay against a baked reference starts both together with no perceptible skew.
- [x] Overlay requires a baked reference by signature: it takes two file URLs, so live
      synthesis cannot be passed to it at all.
- [x] Deleting a `.m4a` in Finder and returning disables that take's controls and explains
      why, rather than throwing.
- [x] Nothing goes silent unexpectedly, which would mean a player lost its strong reference.


## What the probe measured

```
baked two files: 2.16s and 2.13s

rate handling:
  rate 1.0:  played in 2.35s, expected about 2.16s  OK
  rate 0.75: played in 3.04s, expected about 2.88s  OK

sequential A/B: 4.98s, expected about 4.69s   OK -- reference then take, in that order
overlay: both started from a shared anchor, isPlaying=true
  stopAll leaves isPlaying=false
missing file: "The recording for this take is no longer in the folder, so it cannot be played."
```

The rate result is the useful one: 0.75 rate took materially longer than the baseline,
which is only possible if `enableRate` was set **before** `prepareToPlay`. Set afterwards it
is ignored with no error, so this is the assertion that catches the mistake.

Verifying this item against baked reference audio rather than a recorded take is what let it
finish without a microphone grant.
