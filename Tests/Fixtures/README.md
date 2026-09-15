# Scoring fixtures

Item 11 calibrates the scorer against these. Each fixture is one real take, with a
**hand-written** list of which words should be flagged — without that label there is
nothing to tune against but vibes.

## Why hand labels

The scorer has six free parameters: the similarity threshold and five cost-table entries.
Tuning them against a handful of unlabelled transcripts, with the synthetic tests as the
only guard, is circular: those tests encode the same expectations the thresholds are being
tuned to satisfy, so re-running them detects gross breakage and nothing else.

## Shape

One JSON file per take:

```json
{
  "audioFile": "clean-01.m4a",
  "referenceText": "The fog came in on little cat feet.",
  "transcript": "the fog came in on little cat feed",
  "words": [
    { "text": "the", "confidence": 0.95, "startTime": 0.10, "duration": 0.18 }
  ],
  "expectedFlaggedWords": ["feet"],
  "category": "substitution",
  "split": "tuning"
}
```

`category` is one of `clean`, `substitution`, `skip`, `insertion`, `mumbled`, `long`.
`split` is `tuning` or `heldOut`.

## Budget

| Category | Count | What it proves |
| --- | --- | --- |
| clean | 10 | No false penalties on a correct read |
| substitution | 10 | The flagged word is the word actually misread |
| skip | 10 | A dropped word is reported missed, and the following words still match |
| insertion | 10 | Insertions stay cheap relative to deletions |
| mumbled | 5 | The hard-to-hear path triggers instead of a red score |
| long | 5 | Paragraph and whole-passage behavior, including chunk splicing |

Split roughly 30 tuning and 20 held out. **Do not look at the held-out set until the cost
table is frozen.**

## Acceptance metric, to be written down before tuning

- On the held-out set, the flagged-word set matches the labels on at least 80 percent of
  takes.
- Every clean read scores at least 95.
- No clean read triggers the hard-to-hear presentation.
- Every invariant test from item 03 still passes, unchanged.

## Status

**Empty.** Capturing these needs a microphone grant and about an hour of reading, so no
fixture exists yet and the scorer runs on its shipped defaults. See item 11.
