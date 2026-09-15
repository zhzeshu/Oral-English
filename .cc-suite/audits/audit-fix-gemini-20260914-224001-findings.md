# Audit Findings

**Run**: audit-fix-gemini | **Scope**: Sources/Core/Scorer.swift | **Audit type**: mini
**Auditor**: gemini-3.1-pro-high (agy) | **Fixer**: Claude
**Status values**: open | fixed | not-fixed | partial | regressed | skipped

Scoped to the scorer deliberately. It is the file where a silent bug produces a wrong score
the user would trust, and the only file in the project whose output the user cannot sanity
check by ear.

| # | File | Line | Severity | Dimension | Finding | Suggested fix | Status | Round |
|---|------|------|----------|-----------|---------|---------------|--------|-------|
| 1 | Sources/Core/Scorer.swift | 85 | Medium | Logic & Correctness | The `n == 0` early return called `verdict()` without `extraCount`/`referenceTokenCount`, so it used the defaults and skipped the runaway-transcript check | Pass the real counts | fixed | 1 |
| 2 | Sources/Core/Scorer.swift | 111 | Medium | Duplication | The `switch op` block repeated `WordResult` construction across five cases | Set fields in the cases, construct once | fixed | 1 |
| 3 | Sources/Core/Scorer.swift | 218 | Low | Dead Code | `align` used defensive `1...max(n,1) where n > 0` loops, unreachable because `score()` exits early on `n == 0` | Simplify with a single guard | fixed | 1 |
| 4 | Sources/Core/Scorer.swift | 215 | High | Refactoring Debt | The DP tables were arrays-of-arrays, so the shared inner array triggered a copy-on-write allocation per row on first write | Flatten to a contiguous 1D array indexed `i * stride + j` | fixed | 1 |
| 5 | Sources/Core/Scorer.swift | 63 | Low | Shortcuts | The public `score` overload defaulted `engine` to `"test"` — a harness shortcut leaked into the API | Default to the real engine string | fixed | 1 |
| 6 | Sources/Core/Scorer.swift | 94 | Low | Shortcuts | The token-cap path discarded the hypothesis length and hardcoded `.hardToHear`, repurposing an audio flag for a length problem | Set `extraCount: m`; ideally add a dedicated verdict | fixed | 1 |

## Notes on the verdicts

Gemini returned 5 FIXED and 1 PARTIAL after round 1. The partial was finding 6: the
minimum fix had landed but the verdict was still `.hardToHear`.

That was worth finishing rather than accepting, because it is user-facing wrongness, not
tidiness — a five-thousand-word "sentence" would have told the user to move closer to the
microphone. `AudioQualityVerdict` gained `.unsupportedLength`, the row and the take history
show a text icon rather than an ear icon for it, and a test pins the distinction.

Finding 4 was graded High by Gemini and the reasoning was slightly overstated: the
copy-on-write allocations are one per row on first write, which is the same order as the
algorithm itself, so it was a constant-factor issue rather than a complexity one. It was
still worth fixing — `[[Double]](repeating:count:)` genuinely creates N references to one
shared array — and flattening made the code shorter, so it was taken rather than argued
with. All 248 tests, including the 400-case property tests and the alignment tie-break
test, passed unchanged afterwards, which is what gives confidence the refactor preserved
behavior.
