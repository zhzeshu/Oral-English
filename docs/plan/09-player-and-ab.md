# 09 — Player and A/B comparison

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

- [ ] `./test.sh` passes.
- [ ] The probe plays a file and reports a sensible duration.
- [ ] Playing a take from a row sounds correct and stops cleanly.
- [ ] A/B plays reference then take with an audible gap, in that order.
- [ ] A playback speed change is audible, proving `enableRate` was set early enough.
- [ ] Starting a new playback while one runs stops the first rather than mixing.
- [ ] Overlay against a baked reference starts both together with no perceptible skew.
- [ ] The overlay control is disabled when no baked reference exists.
- [ ] Deleting a `.m4a` in Finder and returning disables that take's controls and explains
      why, rather than throwing.
- [ ] Nothing goes silent unexpectedly, which would mean a player lost its strong reference.
