# 03 — Normalizer and scorer

**Status:** DONE — 2026-09-14
**Changed:** Sources/Core/Normalizer.swift, Sources/Core/Scorer.swift,
Tests/NormalizerTests.swift, Tests/ScorerTests.swift
**Verified:** ./test.sh (132 tests in 8 suites passed), ./build.sh (signature verified).
Property tests run 400 randomized reference/transcript pairs per invariant.
**Caveat:** the "before starting" step — capturing three to five real transcripts with the
transcription probe — was **not** done, because it needs a microphone grant and a recording.
The synthetic assumptions about transcript shape are therefore still unvalidated. Item 10
captures the fixtures and item 11 calibrates against them; expect some expectations here to
need rewriting rather than merely retuning.

**Verification style:** test-first. The most test-driven item in the project and the one
where the test loop pays for itself.

> Moved from position 9 to position 3 in revision 2. It is pure, has zero audio
> dependencies, and — decisively — it is the consumer that determines the data model
> vocabulary. Built after the store it forces a schema change once real user data exists;
> built here the schema is complete the first time. Gemini and the architecture review
> agreed independently. Threshold calibration against real speech stays at item 11.

## Goal

Compare a transcript against the target sentence and produce an accuracy score plus a
per-word status, so the app can name the words that were actually wrong.

Both files are pure functions over strings in `Sources/Core/`, so the whole item is built
through `./test.sh` with no microphone, no permissions, and no app launch.

## Before starting

Run the transcription probe once against three to five recordings of yourself, and save the
transcripts. It takes half an hour and stops the scorer being built against imagined
transcript shapes — casing, whether the recognizer emits "3" or "three", how often it
inserts filler. The probe is standalone and needs no app. Without this, some tests written
here will need rewriting at item 11 rather than merely retuning.

## Files

- `Sources/Core/Normalizer.swift`
- `Sources/Core/Scorer.swift`
- `Tests/NormalizerTests.swift`, `Tests/ScorerTests.swift`, `Tests/Fixtures/`

## Red — normalization

Reference and transcript go through one identical pipeline, except where noted.

| Input | Expected tokens |
| --- | --- |
| `"The Fog"` | `[the, fog]` |
| `"don't"` | `[do, not]` — whitelist expansion |
| `"Sandburg's"` | one token, apostrophe stripped; ambiguous possessive is not expanded |
| `"well-known"` | `[well, known]` |
| `"4 p.m."` | abbreviation dots removed |
| `"3"` | matches both `three` and `3` via alternates |
| `"3rd"` | matches `third` |
| `"50%"` | includes `percent` |
| `"um, the fog"` as a transcript | `[the, fog]` — fillers dropped |
| `"um, the fog"` as a reference | `um` retained; fillers drop on one side only |
| curly quotes, accents | folded |
| `"The the fog"` | both `the` tokens retained; repeated words are legal |

Name the similarity function explicitly. Revision 1 specified "similarity at or above
0.72" without saying similarity of what, which makes the constant meaningless and the
`"feet"` against `"feed"` row underivable. Use normalized Levenshtein ratio over
characters, and state it.

Specify how similarity works against a multi-valued token: take the maximum over the
token's alternates. Revision 1 said "exact or alternate match" and never said how a *near*
match interacts with alternates.

## Red — scoring

| Reference | Transcript | Expected |
| --- | --- | --- |
| `"the fog came in"` | identical | accuracy 1.0, all four `match` |
| `"the fog came in"` | `"the fog came on"` | one `substituted`, three `match` |
| `"the fog came in"` | `"the fog in"` | `came` is `missed`, not a substitution |
| `"the fog came in"` | `"the the fog came in"` | one `extra`, four `match`, accuracy above the equivalent deletion case |
| `"feet"` | `"feed"` | `partial`, above a substitution and below a match |
| `"the fog came in"` | `""` | accuracy 0.0, all `missed`, no crash |
| `""` | `""` | accuracy **1.0** |
| `""` | `"anything"` | accuracy **0.0**, all `extra` |
| 4-token reference | 40 spurious words | accuracy **0.0**, never negative |
| a word skipped mid-sentence | | following words still `match` — proves global alignment, not greedy matching |
| `"a"` | `"x y"` | deterministic: `a` is `substituted`, `y` is `extra`, per the stated tie-break |
| reference of 1 token | | no crash |
| ~300 tokens | | correct, and completes inside a stated runtime bound |
| identical but for casing | | accuracy 1.0 |

Property tests over randomized token pairs, using parameterized cases:

- `0 <= accuracy <= 1` for **every** generated input.
- `match + partial + substituted + missed == referenceTokenCount`.
- accuracy is never NaN and never infinite.
- word error rate agrees with the classic unit-cost formula.

**This is the change that matters most in this item.** Revision 1's formula was
`1 − weightedError / referenceLength` with no clamp and no zero-length guard. Measured: 40
extras on a 4-token reference gives **−4.0**, and an empty reference gives **−∞** or NaN.
Item 13 renders accuracy as a muted percentage, so that surfaces as "−400%". NaN also
breaks strict weak ordering in `bestTake`, and `-Onone` keeps Swift's ordering
preconditions enabled, turning it into a hard trap rather than a wrong answer.

## Green

Global alignment with backpointers over the normalized token arrays. **Not** greedy
matching and **not** longest common subsequence: only global alignment attributes
insertions and deletions correctly when a word is skipped mid-sentence, which is exactly
the case a learner cares about.

| Operation | Cost | Status |
| --- | --- | --- |
| exact or alternate match | 0.0 | `match` |
| near match, similarity ≥ 0.72 | 0.5 | `partial` |
| substitution | 1.0 | `substituted` |
| reference word with nothing heard | 1.0 | `missed` |
| heard word with no reference | 0.5 | `extra` |

Insertions cost less than deletions on purpose. On-device recognition over-inserts short
function words far more than it drops content words, and skipping a word is a genuinely
worse reading error than the recognizer inventing an "a". **This asymmetry is the single
biggest driver of whether scores feel fair rather than punitive.** If the user says scores
feel harsh, this table is the first place to look.

Tie-break order on the traceback is explicit: prefer `match`, then `partial`, then
`substituted`, then `missed`, then `extra`. Revision 1 left it unspecified, and with these
costs two insertions tie one substitution, so which word got flagged was decided by
implementation accident — threatening the done-when that a misread word is flagged and no
others.

Accuracy is one minus the weighted error count over the reference length, **clamped to zero
through one**. Store the raw unclamped weighted error alongside it so the over-insertion
signal is not lost, and use "transcript much longer than reference" as a trigger for the
hard-to-hear presentation rather than showing a floor-zero score. Empty reference with
nothing heard is 1.0; empty reference with words heard is 0.0.

Word error rate is stored alongside because it is the standard metric and costs nothing.
Assert the two agree in the cases where they should.

The table is sentence-sized, so the naive quadratic implementation is correct and fast. Do
not optimize it. Do cap the token count for a single target: a 5,000-word "sentence" would
make the table 25 million cells.

## Two honesty constraints

Requirements, not polish. A scoring feature that overstates itself is worse than none.

**Bad audio must not look like bad pronunciation.** The rule is now specified in all four
quadrants rather than as two unnamed thresholds:

| Mean confidence | Accuracy | Presentation |
| --- | --- | --- |
| < 0.30 | < 0.50 | "Hard to hear, try again". No number shown |
| < 0.30 | ≥ 0.50 | Show the score with a muted "some words were hard to hear" note |
| ≥ 0.30 | any | Show the score, however low |

Mean confidence is the duration-weighted mean over all segments. Both constants are marked
tunable at item 11.

**There is a platform risk here.** `SFTranscriptionSegment.confidence` is commonly reported
as 0.0 for on-device results. If it is uniformly zero on this machine, every take would trip
hard-to-hear and the app would never show a score again. Item 10's probe must assert
confidence is non-zero and varying. If it is not, derive the signal from the recorder's own
metering plus the missed-word ratio instead — both already available and independent of
Speech.

**The label reads as words recognized, not a pronunciation grade.** Recognition measures
intelligibility, not accent. Do not imply otherwise anywhere in the UI.

## Presentation

One plain-language line naming what was heard, with close misses in amber and wrong or
dropped words in red. No underlines, no strikethrough, no italics: color alone keeps it
readable as a sentence rather than as markup. Because color alone is not accessible, the
muted line beneath also names the problem words in text.

Build the diff as a single attributed string with per-run styling, which wraps natively.
Cache it per take. Never call the tokenizer or the aligner from a view body.

## Done when

- [x] `./test.sh` passes with every table row asserted.
- [x] The property tests hold over randomized inputs: accuracy always in range, counts
      always summing, never NaN.
- [x] The similarity function and both confidence constants are named in code, not prose.
- [x] `./scripts/check-core-imports.sh` passes.


## Findings while executing this item

Three implementation bugs the tests caught immediately, all of which would have produced
silently wrong scores:

1. **Diacritics were not folded.** `é` is a letter, so it survives punctuation stripping
   untouched, and `café` compared as a different word from `cafe`. Diacritic folding moved
   into the Unicode fold step, where it belongs.
2. **`NLTokenizer` splits `p.m.` into `p` and `m`.** The plan's expectation that
   abbreviation dots vanish into `pm` was therefore unreachable. Dotted abbreviations are
   now collapsed before tokenizing, by a character scan — a regex with a word-boundary
   lookbehind did not match. A single abbreviation such as `Dr.` is deliberately left for
   ordinary punctuation stripping.
3. **Symbol alternates could never fire.** The word tokenizer discards `%` before an
   alternates rule sees it. Symbols are now expanded to words in the text, on both sides
   symmetrically, which is also the better design: there is no competing numeric spelling
   to preserve, so `50%` and `50 percent` simply produce the same tokens.

The asymmetric cost table is verified working as intended: an insertion scores strictly
better than the equivalent deletion, asserted directly rather than assumed.
