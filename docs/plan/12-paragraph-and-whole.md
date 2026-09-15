# 12 — Paragraph and whole passage

**Status:** PARTIAL — 2026-09-14. The granularity control, the row re-targeting and the
nested rendering are built and the abstraction is verified clean; the gates needing recorded
audio are BLOCKED.
**Changed:** Sources/App/AppModel.swift (visible targets, per-target sentences),
Sources/Views/PassageDetailView.swift (segmented control, nested sentences),
Sources/Services/PracticeController.swift (utterance sequencing)
**Verified:** ./test.sh (242 tests in 18 suites), ./build.sh clean, and the leak grep below

**Verification style:** checklist, plus the existing suite must keep passing.

## Goal

Practice at paragraph and whole-passage level, not only sentence level.

## An honest estimate

Revision 1 called this "nearly free" and told the implementer that substantial new code meant
the `TargetRef` abstraction had leaked earlier and should be fixed rather than special-cased.
That instruction was actively misleading, because two pipeline stages branch on granularity by
framework necessity, not by modelling error.

What genuinely is free: storage, scoring, take history and export already work on any
`TargetRef`, so none of them changes. That part of the claim holds.

What is not free: the granularity control, the nested row rendering, and the first real
exercise of the chunking path. The utterance sequencer that paragraph and whole playback need
was moved into item 07, where the one-sentence-per-utterance decision is made, so it is not a
surprise here.

**The real test for a leak** is a granularity check inside the store, the scorer, the export
path, or the take history. Branching inside synthesis or transcription is expected.

## Files

- `Sources/Views/PassageDetailView.swift`, `SentenceRowView.swift`
- `Sources/Services/TranscriberService.swift` — exercise item 10's chunking for real
- `Sources/Services/PracticeController.swift`

## Green

The segmented control is the **only** affordance for the three levels. It re-targets existing
rows rather than adding a second set of controls:

- **Sentence** — one row per sentence. The default and the daily driver.
- **Paragraph** — one row per paragraph, its sentences shown as dimmed body text inside.
- **Whole** — a single row containing the entire passage.

Same component, same three buttons, same vocabulary at every level. Resist paragraph-specific
controls; that is how three granularities become a cluttered interface.

Text for a target is the sentence text, the paragraph text, or all paragraphs joined by blank
lines. Note that the third always contains newlines, which is why item 05 tests CSV newline
escaping.

## Longer audio

Item 10's chunking gets exercised for real. A whole passage read aloud runs well past the
single-request limit. The planning and splicing are already unit-tested, so what this item
verifies is the I/O: real audio, real chunk boundaries, real timings.

Scoring a long target works unchanged, except that the token cap from item 03 applies — the
alignment table is quadratic and a few hundred tokens is fine, but a pathological single
sentence is not.

Highlighting at paragraph and whole level uses the item 07 sequencer: the active sentence, then
the active word within it.

## Done when

- [ ] Switching granularity re-targets the rows and nothing else on screen moves.
      *(PARTIAL: the control is built and re-targets through one shared row component. Seeing
      that nothing moves needs eyes on the screen.)*
- [ ] *(BLOCKED: needs recorded audio)* Recording at paragraph level stores a take under the paragraph target, not a sentence.
- [ ] *(BLOCKED: needs recorded audio)* Recording a whole passage of at least 90 seconds transcribes completely, no truncation.
- [ ] *(BLOCKED: needs recorded audio)* A whole-passage take scores, and the word diff covers the full text.
- [ ] *(BLOCKED: needs recorded audio)* Segment timings increase monotonically across chunk boundaries on real audio.
- [ ] *(BLOCKED: needs recorded audio)* Sentence-level and paragraph-level takes coexist without interfering.
- [ ] *(BLOCKED: needs recorded audio)* Take history at each level shows only that level's takes.
- [ ] *(BLOCKED: needs recorded audio)* Highlighting during paragraph playback tracks the sentence and the word within it.
- [ ] *(BLOCKED: needs recorded audio)* Recording is still possible while a previous take scores, per the two-axis state.
- [x] `grep` finds no granularity check in the store, the scorer, the export path or the
      take history. **Zero** branches in `PassageStore`, `Scorer`, `Normalizer`, `ScoreCSV`
      and `ExportService`; the store never inspects a `TargetRef`'s kind at all, and the CSV
      uses it only as a column value. Branching is confined to `Models` (text resolution),
      `AppModel` (visible targets) and `PassageDetailView` (nested rendering) — exactly the
      places where it is expected.
- [x] `./test.sh` passes.


## The estimate was honest

Re-framing this item away from "nearly free" was right. What was genuinely free: the store,
the scorer, the CSV and the export path all work on any `TargetRef` and needed **no**
changes at all, which the leak grep confirms. What was not free: the granularity control,
the nested row rendering, and the per-target sentence resolution — plus the utterance
sequencer, which was moved into item 07 where the one-sentence-per-utterance decision is
made rather than being discovered here.

Sentence-level take separation is covered by test at the store layer
(`takes(for:)` returns only the matching target's takes), so the coexistence question is
answered for the data even though it is unexercised for the audio.
