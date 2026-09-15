# 11 — Score calibration

**Status:** BLOCKED — 2026-09-14
**Blocker:** calibration needs roughly fifty recordings of the user's own voice, each
hand-labelled with which words were deliberately misread. That cannot be produced without a
microphone grant and about an hour of reading. The scorer therefore runs on its shipped
defaults, tuned against synthetic cases only.
**Changed:** Tests/CalibrationTests.swift, Tests/Fixtures/README.md
**Verified:** the harness exists and runs. With no fixtures it prints
"CALIBRATION NOT RUN" and explains why, rather than passing quietly — a calibration suite
that reports success on an empty directory is worse than no suite.

**Verification style:** test-first, against committed fixtures with a held-out split.

> This is the second half of revision 1's item 09. The scorer was built at item 03 against
> synthetic strings; this item tunes it against real speech. Splitting them is what let the
> pure logic move to position 3.

## Goal

Make the scores feel fair on this user's actual voice, without breaking the correctness
invariants item 03 established.

## Files

- `Tests/Fixtures/` — committed labelled fixtures
- `Sources/Core/Normalizer.swift`, `Sources/Core/Scorer.swift` — constants only
- `Tests/CalibrationTests.swift`

## The methodology problem this item fixes

Revision 1 tuned up to six free parameters — the similarity threshold plus five cost-table
entries — against "several" transcripts from one speaker, one microphone, one room, with the
synthetic tests as "the guard rail that stops tuning from breaking correctness".

That guard rail is circular. The synthetic tests encode the *same* expectations the thresholds
are being tuned to satisfy: the row asserting `"feet"` against `"feed"` is a `partial` directly
pins the threshold below their similarity. Re-running them after tuning detects gross breakage
only, and if a real transcript demands a threshold that violates a synthetic row, revision 1
gave no rule for which wins. There was also no acceptance metric, so nothing distinguished
"tuned" from "fiddled with until I stopped noticing", and fixtures had no path, no format and
no home in the repo.

## Two test suites, different jobs

State this distinction in code, not just here.

**Invariant tests** (item 03) assert bounds, count sums and alignment structure. They must
**never** move during calibration. If tuning would break one, the tuning is wrong.

**Calibration tests** (this item) assert agreement with hand-written labels. They are expected
to move, and moving them is the work.

## The fixtures

Commit as JSON under `Tests/Fixtures/`, each holding the audio filename, the transcript, the
segments with confidence and timing, the reference text, and — the part that makes this work —
a **hand-written list of which words should be flagged**. Without labels there is nothing to
tune against but vibes.

Roughly fifty takes:

| Category | Count | Purpose |
| --- | --- | --- |
| Clean reads | 10 | No false penalties |
| Exactly one deliberate substitution | 10 | The word flagged is that word |
| Exactly one deliberate skip | 10 | Reported missed, following words still match |
| Deliberate filler or insertion | 10 | Insertions stay cheap |
| Mumbled or quiet | 5 | Hard-to-hear path triggers |
| Paragraph or whole length | 5 | Long-target behavior and chunk splicing |

Split about thirty for tuning and twenty held out. **Do not look at the held-out set until the
cost table is frozen.**

## The acceptance metric, defined before tuning

- On the held-out set, the flagged-word set matches the labels on at least 80 percent of takes.
- Every clean read scores at least 95.
- No clean read triggers the hard-to-hear presentation.
- Every invariant test from item 03 still passes.

Write these numbers down before touching a constant. That is the difference between calibration
and fiddling.

## What may be tuned

Only these, and only these:

- The similarity threshold, currently 0.72.
- The five cost-table entries.
- The two hard-to-hear constants, currently confidence 0.30 and accuracy 0.50.

The cost asymmetry is the biggest lever on whether scores feel punitive. If the user says
scores feel harsh, raise the insertion cost relative to deletion here rather than anywhere else.

## Re-scoring

Keeping every take pays off here: a re-score action re-runs the tuned scorer over stored audio,
so tuning improves old results instead of invalidating them. Report partial success honestly —
"scored 18 of 20 takes; 2 recordings are missing" — rather than failing the batch or silently
skipping.

## Done when

- [ ] At least fifty labelled fixtures are committed, with the stated category spread.
- [ ] The tuning and held-out split is recorded, and the held-out set was not consulted during
      tuning.
- [ ] The acceptance metric was written down before tuning and is met on the held-out set.
- [ ] Every item 03 invariant test still passes unchanged.
- [ ] `./test.sh` passes.
- [ ] Reading a sentence correctly scores at or near 100.
- [ ] Deliberately misreading one word flags **that** word and no others.
- [ ] Deliberately skipping one word reports it missed, and following words still match.
- [ ] A mumbled take reports hard to hear rather than a red score.
- [ ] Re-scoring an old take updates its result in place.


## What is ready

The harness is built and the methodology is encoded, so this becomes an hour of reading
rather than a design problem:

- `Tests/Fixtures/README.md` specifies the JSON shape, the six categories with counts, the
  tuning and held-out split, and the acceptance metric — written down **before** tuning, so
  there is a difference between calibrated and fiddled-with.
- `CalibrationTests` asserts clean reads score at least 95, mumbled takes do not read as
  clear, held-out flagged-word agreement is at least 80 percent, and every fixture actually
  carries a label.
- A separate test pins the six tunable constants, so the invariant suite from item 03 and
  the calibration suite cannot be confused for each other. Invariants must never move
  during tuning; calibration is expected to.

## To unblock

1. Grant the microphone and speech recognition.
2. Check first whether `SFTranscriptionSegment.confidence` is non-zero on this machine. If
   it is uniformly 0.0, the hard-to-hear rule rests on a constant and item 03's fallback
   applies. This is the single highest-value thing to check.
3. Record the six categories, roughly fifty takes, and label each one.
4. Split about thirty tuning and twenty held out, and do not look at the held-out set until
   the cost table is frozen.
