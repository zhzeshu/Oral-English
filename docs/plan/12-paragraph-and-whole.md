# 12 — Paragraph and whole passage

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
- [ ] Recording at paragraph level stores a take under the paragraph target, not a sentence.
- [ ] Recording a whole passage of at least 90 seconds transcribes completely, no truncation.
- [ ] A whole-passage take scores, and the word diff covers the full text.
- [ ] Segment timings increase monotonically across chunk boundaries on real audio.
- [ ] Sentence-level and paragraph-level takes coexist without interfering.
- [ ] Take history at each level shows only that level's takes.
- [ ] Highlighting during paragraph playback tracks the sentence and the word within it.
- [ ] Recording is still possible while a previous take scores, per the two-axis state.
- [ ] `grep` finds no granularity check in the store, the scorer, the export path or the take
      history.
- [ ] `./test.sh` passes.
