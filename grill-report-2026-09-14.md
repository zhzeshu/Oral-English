---
plugin: grill
version: 1.3.0
date: 2026-09-14
target: /Users/zackzhang/Developer/Oral-English/docs/plan
style: Paranoid Mode (Edge Case Gauntlet)
addons: Assumptions audit
agents: recon, architecture, error-handling, security, testing, edge-cases
---

# Grill report — Oral English implementation plan

Target is a pre-implementation repository: thirteen plan files under `docs/plan/`, plus
`README.md`, `build.sh`, `make-cert.sh`, and `Resources/Info.plist`. Zero Swift files
exist. Findings are therefore against the plan as written and against the two shell
scripts, which are real reviewable code.

Six agents ran. Where agents disagreed, I re-verified the claim myself with read-only
commands and throwaway compiles; those adjudications are marked.

---

## Adjudicated disagreement

One conflict mattered enough to settle before anything else.

The testing agent reported that swift-testing **is** available with Command Line Tools.
The edge-cases agent reported that it compiles but fails at runtime with
`dyld: Library not loaded: @rpath/lib_TestingInterop.dylib`.

**The testing agent is right.** The missing dylib exists at
`/Library/Developer/CommandLineTools/Library/Developer/usr/lib/lib_TestingInterop.dylib`;
the edge-cases agent simply had not added that directory as an rpath. I built and ran a
real suite with Command Line Tools only:

```
✔ Test slugLowercases() passed after 0.001 seconds.
✔ Test tableDriven(input:expected:) with 2 test cases passed after 0.001 seconds.
✘ Test deliberateFailure() recorded an issue at Tests.swift:9:34:
    Expectation failed: (slug("A B") → "a-b") == "WRONG"
exit with failing test: 1
exit with all passing: 0
```

Automatic discovery, expression-capturing diagnostics, file and line, parameterized
`@Test(arguments:)`, correct exit codes. The plan's claim at `00-overview.md:52` is false,
and the hand-rolled runner it justifies is unnecessary.

---

## [CRITICAL] findings

### C1. `build.sh` reports success when `codesign` fails, installing an unsigned app

- **File**: `build.sh:62-64`
- **Observation**: Both the signing and verification steps pipe through `grep` and end in
  `|| true`, discarding the exit status. The script then unconditionally installs to
  `~/Applications` and prints `built -> ...` with exit 0. Found independently by four of
  five agents.
- **Severity**: `[CRITICAL]`
- **Evidence**:
  ```bash
  codesign --force --sign "$SIGN_ID" --identifier "$BUNDLE_ID" --timestamp=none "$STAGE" 2>&1 \
      | grep -v 'replacing existing signature' || true
  codesign --verify --verbose=2 "$STAGE" 2>&1 | grep -v '^.*: valid on disk$' || true
  ```
  `set -o pipefail` is active at line 15 and would propagate the failure correctly; `|| true`
  throws it away. This directly defeats `01-bundle-and-signing.md:72,74`, which require that
  the build complete with no codesign warnings and that verify pass. The `|| true` is not
  gratuitous — `grep -v` exits 1 when it filters every line, which is the success case — but
  the fix is to separate status from display, not to suppress both.
- **Proposed change**: Capture output, check status, filter only for display, exit non-zero
  on failure. Gate the install on verification passing so a failed build leaves the last
  working app in place. Add an explicit assertion that the signature is not ad-hoc when a
  certificate is expected.
- **Tradeoff**: Four more lines of shell. Nothing is lost; noise suppression is preserved by
  filtering displayed text rather than discarding status.
- **Effort**: `[< 1 day]`

### C2. `make-cert.sh` dies silently on a stock Mac

- **File**: `make-cert.sh:36-39`, with `set -euo pipefail` at `:14`
- **Observation**: The script depends on `openssl pkcs12 -export -legacy`, an OpenSSL 3 flag
  that the system openssl does not support, and routes stderr to `/dev/null`. On any Mac
  where Homebrew openssl is not first on `PATH`, it exits non-zero with no diagnostic, and
  the helpful fallback text at `:53-58` is never reached.
- **Severity**: `[CRITICAL]`
- **Evidence**: I verified on this machine:
  ```
  /usr/bin/openssl version        → LibreSSL 3.3.6
  /usr/bin/openssl pkcs12 -export -legacy ...  → unknown option '-legacy'
  /opt/homebrew/bin/openssl version → OpenSSL 3.6.2   (works)
  which -a openssl → /opt/homebrew/bin/openssl, then /usr/bin/openssl
  ```
  `-legacy` is mandatory, not incidental: macOS `security import` cannot read OpenSSL 3's
  default PKCS#12 encryption. So the flag is required and unavailable on the system tool.
  The script works here only because Homebrew shadows `/usr/bin`.
- **Proposed change**: Resolve openssl into a variable, preflight for `-legacy` support, and
  fail with the Keychain Access fallback instructions. Remove `2>/dev/null` from both openssl
  calls — under `set -e` these only produce output when something is wrong.
- **Tradeoff**: Adds a hard OpenSSL 3 dependency to the documented happy path, or an explicit
  pointer to the GUI route. Better than a silent exit.
- **Effort**: `[< 1 day]`

### C3. The testing strategy rests on a false claim, and the hand-rolled runner is avoidable

- **File**: `docs/plan/00-overview.md:51-53`, `:62-64`; consequences at `02-core-models-and-naming.md:9,14`
- **Observation**: The plan asserts XCTest and swift-testing are both unavailable "Ships with
  Xcode, not Command Line Tools", and derives the entire custom-runner strategy from it. The
  XCTest half is correct. The swift-testing half is false. See the adjudication above.
- **Severity**: `[CRITICAL]` — it changes what work item 02 has to build and deletes an entire
  class of risk.
- **Evidence**: `Testing.framework`, `libTestingMacros.dylib`, and `lib_TestingInterop.dylib`
  all ship with Command Line Tools. The working invocation needs three extra flags:
  ```
  -F  $CLT/Library/Developer/Frameworks -framework Testing
  -plugin-path $CLT/usr/lib/swift/host/plugins/testing
  -Xlinker -rpath -Xlinker $CLT/Library/Developer/Frameworks
  -Xlinker -rpath -Xlinker $CLT/Library/Developer/usr/lib
  ```
  plus a two-line `@main` entry point calling `Testing.__swiftPMEntryPoint()`. What misled the
  original check: `swift test` fails because SwiftPM looks for Xcode's `Platforms` directory
  and does not wire the framework path. That is a SwiftPM integration gap, not an absent library.
- **Proposed change**: Delete the hand-rolled runner from item 02. Keep `test.sh`, compiling
  against `-framework Testing`. Pin the three toolchain paths in one variable with a
  fail-loudly guard, since they are unversioned internals. Correct `00:52` and `00:53`.
- **Tradeoff**: The paths are undocumented and could move in a future Command Line Tools
  release; a Foundation-only runner cannot break that way. That risk fails loudly at compile
  time, which is the opposite of a hand-rolled runner's silent-false-negative mode. Against it:
  automatic discovery, Apple-maintained diagnostics, parameterized tests that match the plan's
  table style exactly, no bootstrap problem, and a clean path to `swift test` if Xcode ever
  arrives.
- **Effort**: `[< 1 day]`

### C4. Two of the four test-first items test code the test target cannot compile

- **File**: `docs/plan/00-overview.md:70,74-76` versus `03-store-and-first-screen.md:12,16`
  and `11-export.md:12,14`
- **Observation**: `test.sh` is defined as compiling `Sources/Core/` plus `Tests/`, and the
  purity rule is scoped to `Sources/Core/`. But `PassageStore.swift` and `ExportService.swift`
  are declared under `Sources/Services/`, and both have test-first test files with eleven and
  five assertion rows. Those tests cannot link. They are two of the four items the overview
  calls real red-green-refactor, and item 03 itself names its corrupt-file and concurrent-append
  tests as "the two that matter most" — exactly the tests that will not build.
- **Severity**: `[CRITICAL]`
- **Evidence**: `00:70` — "That compiles `Sources/Core/`, `Tests/`, and the runner". `00:112-115`
  places both files under `Services/`.
- **Proposed change**: The rule is stated against the wrong thing. It should govern the test
  target's import closure, not a directory name. Move `PassageStore` into the test-compiled tree
  (it needs only Foundation), split the pure half of export into `ScoreCSV.swift` and
  `ExportNaming.swift`, and leave `ExportService.swift` as a thin shell owning only the save
  dialog and the subprocess. Restate the rule as "every file compiled by `test.sh` imports only
  Foundation and NaturalLanguage" and enforce it mechanically.
- **Tradeoff**: `Core/` stops meaning "pure domain logic" and starts meaning "testable without
  frameworks" — an actor doing real I/O sits beside pure value types. Worth paying, since the
  entire quality strategy rests on `test.sh`. Use `Core/` plus `Store/` and compile both if the
  tidiness matters.
- **Effort**: `[< 1 day]` now; a cross-cutting rename plus two rewritten test files if deferred to item 11.

### C5. There is no observability of any kind, and item 12 forbids the last surviving evidence

- **File**: all thirteen plan files; compounded by `12-polish.md:51,68`
- **Observation**: Not one line in 1,380 lines mentions logging, `os_log`, a diagnostic surface,
  a log file, or crash handling. Item 12 then requires "No raw error strings" as a done-when, so
  an `NSError` from the recognizer, recorder, or `replaceItemAt` is mapped to one friendly
  sentence and the domain, code, and underlying error are destroyed with nothing written anywhere.
- **Severity**: `[CRITICAL]`
- **Evidence**: A keyword sweep across `docs/plan/` returns zero real hits for
  `log|os_log|diagnos|telemetr|Console|metric|trace`. Meanwhile the plan documents **five**
  distinct silent failure modes: TCC silent denial (`01:29-30`), synthesis producing zero frames
  without a run loop (`04:42-47`), an encoder yielding an unplayable file with no error
  (`06:37-39`), `enableRate` changes ignored with no error (`07:36-37`), and a sample-rate key
  passed as `Int` being silently ignored (`06:39`). It provides zero instrumentation to
  distinguish them at runtime. Item 08 already knows the exact domain and code is the
  load-bearing diagnostic detail — it matches on `kAFAssistantErrorDomain` 1110 — and then the
  plan throws that detail away everywhere else.
- **Proposed change**: Add a Foundation-only `Log.swift` to item 02 with a logger per subsystem,
  and one rule: every `catch` logs the full error and the mapped user copy. Add "Copy
  diagnostics" to the ellipsis menu dumping recent entries plus environment. Amend `12:51` to
  "no raw error strings **in the UI**; every error is logged in full."
- **Tradeoff**: About forty lines, one menu item, and a small discipline tax per catch site.
  `os_log` is free when nobody reads it. The single-user argument correctly kills metrics and
  crash reporting — there is no server — but not logging. The user here is also the developer,
  with no CI and a failure surface made entirely of invisible things.
- **Effort**: `[< 1 day]`

### C6. The delegate shim has no deadline, so a callback that never fires hangs the app permanently

- **File**: `docs/plan/06-recorder.md:56-65`, reused by `07:48-51` and `08:49-51`
- **Observation**: The plan identifies the hazard and covers only one cause. It requires
  resuming exactly once on both the success and error paths — which helps only when a callback
  *arrives*. A callback that never arrives is unhandled, and there is no timeout, deadline,
  watchdog, or cancellation anywhere in the plan. Zero grep hits for `timeout|deadline|watchdog`.
- **Severity**: `[CRITICAL]`
- **Evidence**: Four realistic never-fires paths, all inside normal operation: the input device
  vanishing mid-take; machine sleep mid-recording; the recognition task stalling while the
  on-device asset is mid-download, which is a state `08:61-62` explicitly warns is reachable;
  and synthesis producing no callbacks, which `04:42-47` confirms happens silently. The
  consequence compounds: because `PracticeController` binds every control to a single exclusive
  activity, one unresumed continuation disables the entire UI until force quit — and a force
  quit during recording collides with the termination-import path, discarding the take the plan
  promises never to lose. With C5, none of this leaves a trace.
- **Proposed change**: Make the deadline part of the shim contract, not an afterthought. Budgets
  relative to the work: recorder finish 5 s after stop; player finish duration plus 2 s;
  synthesis word callback 10 s of silence; recognition max(15 s, twice audio duration). On
  timeout, resume with an error, log context, reset to idle, and for the recorder still import
  whatever bytes exist — a truncated file beats nothing.
- **Tradeoff**: Timeout constants need tuning against a slow machine and a long whole-passage
  take, which is why the budgets scale with audio duration rather than being absolute.
- **Effort**: `[< 1 week]`

### C7. The library lives in `~/Documents`, which is iCloud-synced by default, and iCloud is never mentioned

- **File**: `docs/plan/00-overview.md:25`, `03-store-and-first-screen.md:48-54,80-81`
- **Observation**: Storage is `~/Documents/Oral English/`. With iCloud "Desktop & Documents
  Folders" enabled — a default-on prompt most users accept — that path is a synced, evictable
  ubiquitous container. Zero occurrences of `iCloud`, `NSFileCoordinator`, `NSMetadataQuery`,
  `.nosync`, or `isUbiquitousItem` across the plan.
- **Severity**: `[CRITICAL]`
- **Evidence**: Three concrete breakages. Eviction turns an old `.m4a` into a dataless
  placeholder, and `AVAudioPlayer(contentsOf:)` either blocks on demand-download or fails, with
  no missing-audio path anywhere. `replaceItemAt`, the atomic-save primitive, is exactly the
  operation that produces iCloud conflict duplicates — a `passage 2.json` would then be scanned
  and either marked broken or loaded stale. And the concurrent-append test proves safety against
  this process's actor, not against `bird` rewriting the file underneath.
  Mitigating fact I verified: `~/Documents` on this machine is a real local directory
  (`drwx------+`), so sync is currently **off**. But iCloud Drive is provisioned, and enabling
  Desktop & Documents is one toggle.
- **Proposed change**: Decide explicitly and write it down. Either detect the ubiquitous case at
  `ensureLibrary` and warn, route reads and writes through `NSFileCoordinator`, and handle
  dataless files; or state "iCloud Documents sync must be off" as a hard prerequisite in the
  README. Either is defensible. Silence is not.
- **Tradeoff**: `NSFileCoordinator` complicates the clean actor model and the temp-directory
  tests stop exercising the real path. The prerequisite route costs nothing but constrains the
  user's machine configuration.
- **Effort**: `[< 1 week]` to handle; `[< 1 day]` to document as a prerequisite.

---

## [HIGH] findings

Condensed. Each was reported with file, evidence, and a proposed change by the named agent.

| # | Finding | File | Agent |
| --- | --- | --- | --- |
| H1 | **Accuracy is unbounded and can be NaN.** `1 − weightedError/refLen` with extras at 0.5 and no clamp: measured −4.0 for 40 extras on a 4-token reference, and `-inf`/NaN for an empty reference. Item 12 renders this as a muted percentage, so it shows "−400%". NaN also breaks strict weak ordering in `bestTake`, and `-Onone` keeps Swift's ordering preconditions enabled, making it a hard trap. The plan's own test row says only "accuracy defined". | `09:51-52,68-75,82-83` | testing, edge-cases |
| H2 | **The paragraph splitter contradicts its own test table.** The algorithm says split on blank lines, falling back to single newlines when that yields one chunk. The table requires `"Line one.\nLine two."` → 1 paragraph. Trace it: one chunk, so the fallback fires, giving 2 paragraphs. No implementation satisfies both. CRLF text never takes the blank-line path at all, since `\r\n\r\n` contains no `\n\n`. | `02:31` vs `02:77-78` | edge-cases |
| H3 | **Two app copies exist by construction and nothing locks the library.** `build.sh` leaves a launchable copy in `build/` and dittos another to `~/Applications`, same bundle id. Two instances give classic read-modify-write loss: atomic `replaceItemAt` makes it worse, guaranteeing each write is individually clean so there is no corruption to detect. | `03:34,44-46`, `build.sh:36-68` | edge-cases |
| H4 | **The termination rescue is unimplementable as specified.** Item 06 requires awaiting the finish delegate before reading the file, then prescribes stop-and-import on termination. `applicationWillTerminate` is synchronous and time-boxed; it cannot await an AVFoundation delegate. It also only fires on graceful quit, so force quit, crash, and power loss silently leave a header-less `.m4a` that `passage.json` already references. | `06:46-53` | architecture, edge-cases |
| H5 | **`security import -A` grants key access to every process.** Any same-user process can sign a binary with this certificate and `--identifier com.zackzhang.oralenglish`, satisfy the TCC designated requirement, and inherit the microphone grant with no prompt. The two `-T` flags are dead, since `-A` supersedes them. | `make-cert.sh:42-45` | security |
| H6 | **No preferences layer exists**, yet six requirements need one: selected voice, rate, first-run banner flag, and last-selected passage. No file, no owner, no `UserDefaults` mention. The detail pane displays a voice that no model field stores. | `00:99-121` vs `03:66`, `04:70-73`, `12:41` | architecture |
| H7 | **One exclusive activity enum cannot hold both device exclusivity and background scoring.** If `scoring` occupies the slot, the user cannot record the next sentence while a take scores, breaking item 12's own checklist row asserting the UI stays smooth during scoring. If it does not, the enum is not exclusive. Baking a reference file is a third long activity, also absent. | `06:67-73` vs `12:44-46,71` | architecture |
| H8 | **"PassageStore owns every filesystem touch" is false for five services.** The recorder writes an `.m4a`, the player reads one, the voice provider bakes a file, the transcriber reads into buffers, and export runs `ditto` over the tree. The rule will be silently violated or force pointless funneling of audio bytes through an actor. | `03:44` vs `04:53`, `06:29-42`, `07:25`, `08:39-41`, `11:45-48` | architecture |
| H9 | **Whole-passage-as-one-document plus keep-every-take-forever is rewrite amplification.** Every take appends to a flat array in one pretty-printed JSON rewritten in full on every append and re-score, with unbounded retention by explicit decision. Transcript fidelity is never decided, which swings file size by an order of magnitude. | `02:63-73`, `03:49-54` | architecture |
| H10 | **The concurrent-append test validates the actor, not the real hazard.** An actor serializes calls to itself, so the specified test passes trivially. The lost update lives one layer up, in read-from-cache, mutate, `save(wholePassage)` across an `await`. The plan creates three such mutation sources. | `03:33,38,56` | architecture |
| H11 | **`TargetRef.id` is unspecified for paragraph and whole-passage**, while export asks for a "target index". If the id is an index rather than a stable UUID, any edit or re-split silently re-points every historical take. This is baked into the on-disk format at item 02 and expensive to change later. | `00:123`, `02:63-65`, `11:35` | architecture |
| H12 | **A missing audio file has no handling anywhere.** `audioPath` is relative and never validated. The plan invites the user into the folder, so a deleted `.m4a` is a matter of time. Item 07 lists four playback gotchas and "the file is not there" is not among them. Re-score has the same gap. | `02:68`, `07` entire, `09:116-118` | error-handling |
| H13 | **Disk-full is unhandled at every write point**, including mid-recording, where the plan's own cardinal rule is that spoken audio must never be discarded. `record()`'s `Bool` is checked only at start. | `06:27-42`, `03:48-50`, `11:44-52` | error-handling |
| H14 | **Input device loss mid-recording is unhandled, and the plan mistakes a missing API for a missing problem.** `AVAudioSession` being unavailable on macOS does not mean routes never change — it means route-change events must come from Core Audio or `AVCaptureDevice` instead. AirPods disconnecting mid-sentence is the most everyday interruption imaginable and is the never-fires case of C6. | `00:50`, `06` entire | error-handling |
| H15 | **No unified error type.** Five incompatible failure representations across items 02, 03, 06, 07, 08, and 11, and item 12 then demands uniform one-sentence copy over all of them via a mapping layer no item owns and no test covers. | `02:58-59`, `06:39-40`, `08:53-59`, `11:44-48`, `12:51` | error-handling |
| H16 | **Export has no failure handling and mutates the library non-atomically.** The `ditto` shell-out has no exit-status check, no partial-zip cleanup, and no space preflight. Separately, regenerating `scores.csv` directly into the passage folder contradicts item 03's atomic-write rule. Nothing blocks export while recording, so `ditto` can archive an unfinalized `.m4a`. | `11:44-52` | error-handling |
| H17 | **A corrupt library is detected and then permanently unfixable.** Item 03 marks a folder broken and stops: no repair, no quarantine, no way to delete a broken entry (it has no decodable `Passage` to delete). No migration exists in either direction, so one schema bump renders the library permanently broken. | `03:29,86`, `02:58-59` | error-handling |
| H18 | **Threshold tuning overfits and the stated guard rail is circular.** Six free parameters tuned against "several" transcripts from one speaker, one microphone, one room, with no held-out set and no acceptance metric. The synthetic tests encode the same expectations being tuned to, so re-running them detects gross breakage only. Fixtures have no path, format, or home in the repo. | `09:111-118`, `08:28-30` | testing |
| H19 | **Nothing enforces that a later item keeps an earlier one green.** Only two of twelve items ask that `test.sh` still pass, both as hand-ticked checkboxes. No CI, no git repository, no hook, no history to bisect. The plan actively creates a regression path by sharing the slug function between folder and export naming. | `10:69`, `12:72` | testing |
| H20 | **Roughly half the app is unguarded, but most of that is a choice rather than a constraint.** Eight of twelve items have no automated protection, yet at least seven pure-logic units inside them could be tested with modest boundary changes: the audio state machine, chunk planning and timestamp offsetting, UTF-16 range conversion, the permission degradation matrix, voice tier ranking, the encoder settings dictionary, and the decibel conversion. | `00:86-94` | testing |
| H21 | **Titles that slug to empty produce the double hyphen the plan forbids.** Measured: `"???"`, `"中文标题"`, `"…"`, `"🎉🎉🎉"` all slug to `""`, giving `2026-09-14-interview-prep--a1b2`. An all-CJK title is the most likely non-ASCII title a Chinese-speaking English learner will type. Separately, the length cap is unnamed; the real limit is 255 characters per component, and 256 hard-fails. | `02:37-43`, `11:21-27` | testing, edge-cases |
| H22 | **The "hard to hear" honesty constraint is not implementable.** Two unnamed thresholds, "mean confidence" undefined, and the corresponding test row has an empty input cell. Worse, `SFTranscriptionSegment.confidence` is commonly 0.0 for on-device results — if so, every take trips the constraint and the app never shows a score again. Item 08's checklist never asserts confidence is non-zero. | `09:54,88-98` | error-handling, testing |
| H23 | **Passage editing is asserted-about but unowned.** Item 02 justifies the `referenceText` snapshot by "editing a passage later", and item 12 puts rename in the menu, but no item implements either and it is not in out-of-scope. Rename is not free: the folder name embeds the title. Re-splitting edited text changes sentence identity. | `02:67`, `12:41` | architecture, error-handling |
| H24 | **No hardened runtime**, bundled into the sandbox decision and never justified separately. Without it `DYLD_INSERT_LIBRARIES` works, so any same-user process can inject into the app and use the microphone under its grant — the same escalation as H5 by a route that needs no signing key. `--options runtime` works with a self-signed certificate and costs nothing here. | `build.sh:62`, `01:64-66` | security |

---

## [MEDIUM] and [LOW] findings

| # | Finding | File |
| --- | --- | --- |
| M1 | Non-English pasted text produces a confidently wrong zero score. The honesty constraint is conditioned on low confidence, and recognizer confidence on English-shaped noise may be high, so this failure has the wrong shape to be caught. | `02:79`, `09:88-98` |
| M2 | Recognizer locale never specified. Verified: `en-GB` and `zh-CN` report `available=true` but `onDevice=false`, so a naive availability check passes while the plan's own never-fall-back rule then leaves an en-GB user with no scoring at all. | `08:61-63`, `05:43` |
| M3 | Reference audio is 22050 Hz, recordings are 44100 Hz, mismatch undocumented. Playback resamples transparently, but item 08's buffer-feeding path takes its format from the buffers, and a rate mismatch yields gibberish that item 09 scores as bad pronunciation. Synthesis also returns non-interleaved buffers. | `00:48` vs `06:31`, `08:37-44` |
| M4 | Deleting or editing a passage while scoring is in flight is unspecified. Trashing relocates the file under a running recognizer, producing an error the item 08 table does not cover. Nothing cancels the job. | `03:46`, `08:56-59` |
| M5 | `tccutil reset`, the documented recovery, fails in exactly the wedged state it is documented for. Verified: `No such bundle identifier ... OSStatus error -10814`, exit 64. Both documented escape hatches fail together with C2. | `build.sh:12-14`, `01:38` |
| M6 | Control characters and NUL survive into storage. Verified: NUL splits a sentence and is kept in the token, round-trips through JSON, and silently collapses a file URL's `.path` to the empty string — which would then be misdiagnosed as the absolute-path bug item 11 warns about. | `02:24-33` |
| M7 | The Core purity rule, on which the whole test strategy rests, is enforced only by a manual grep in one checklist, once, on the smallest version of the codebase. `build.sh` compiles Core and Services as one module, so a violating import breaks only `test.sh`, later, far from the edit. | `build.sh:42-56`, `02:93` |
| M8 | `takes(for:)` and `bestTake(for:)` are scans over all takes and nothing forbids calling them from a view body. Item 12 forbids the tokenizer and aligner there but says nothing about the two array scans that will dominate. The proposed row-input mitigation stops rows re-bodying but not the parent recomputing them. | `02:55-57`, `12:57-59` |
| M9 | `TargetRef` holds for data and leaks for media, and item 10's "fix the leak" instruction is not actionable. Transcription branches on duration and synthesis needs a per-sentence utterance sequencer plus two-level highlight state — inherent to the frameworks, not a modelling error. Item 10 is not "nearly free". | `10:10-18,32-36,42-56` |
| M10 | Sequencing: the pure scorer is scheduled ninth though the plan concedes it is order-free, and it is the consumer that determines the model vocabulary — it needs a transcript type with confidence that item 02's model list does not contain. So the on-disk schema is provably incomplete, surfacing after nine files and real user data depend on it. | `00:132-154`, `09:11-12` |
| M11 | Item 11's CSV matrix omits embedded newlines, which are guaranteed on every whole-passage row since that target text is paragraphs joined by blank lines. Also no formula-injection row, no encoding assertion, and two library exports on one day collide. | `11:22-26,33-41` |
| M12 | Item 03's store tests have no error paths and none for the user editing the deliberately-visible folder: no read-only save, no stale `.tmp` from a crashed run, no hand-renamed folder, no delete-to-Trash test. | `03:20-40` |
| M13 | Item 02's naming tests miss the empty-slug case, the length cap is unnamed, "does not cut mid-escape" contradicts the plain-ASCII slug spec, there is no timezone test though the date leads every folder name, and the ISO-8601 assertion greps for the literal `"2026-` so it passes on partial compliance and rots next year. | `02:36-46,55` |
| M14 | Both subjective gates are unfalsifiable as written, and each sits beside automatable content left unautomated. Nothing asserts programmatically that the selected voice is above the lowest tier — the exact regression that motivates item 04 and is inaudible to someone who has forgotten the baseline. | `04:91-92`, `12:61-73` |
| M15 | `README.md` documents `./run.sh` and `./test.sh`; neither exists. The overview states the runner "was verified working before the plan was written" while no runner is in the repo. This is the one place the plan's evidence discipline breaks. | `README:22-32`, `00:63-64` |
| M16 | The overview says the third requirement is unknown and must be asked about; item 10 says it closes the third requirement. One of twelve items claims to satisfy a requirement the overview says nobody knows. | `00:161-165` vs `10:7-8` |
| L1 | `BannerView` is written to by four items with no owner and no precedence rule, and its lifetime is specified twice inconsistently. | `04:35,64-67` vs `05:19,44` |
| L2 | `ORAL_SIGN_ID=-` produces an ad-hoc build at the same path with the same bundle id and no warning, quietly leading the user into destroying a working TCC grant. | `build.sh:8,25,29` |
| L3 | `$SIGN_ID` is interpolated into `grep` as an unanchored regex, so metacharacters match unintended identities and duplicate names pass the check while `codesign` fails as ambiguous. | `build.sh:29`, `make-cert.sh:21,48` |
| L4 | Unquoted `$SRC` word-splits on any source path containing a space. Verified: a directory named `My Core` produces two nonexistent paths. | `build.sh:44,50,56` |
| L5 | Empty-password PKCS#12 survives on disk after SIGKILL or power loss. Verified: the EXIT trap fires on SIGTERM and `set -e` aborts, but not SIGKILL. Strictly less severe than H5. | `make-cert.sh:18-19,36-39` |
| L6 | `scores.csv` is a formula-injection sink; the escaping tests cover commas and quotes but not a leading `=`, `+`, `-`, or `@`. The zip is explicitly shareable. | `11:35-41` |
| L7 | Every export ships raw voice audio; no transcripts-only variant, though sharing with a tutor is the likeliest reason to export. The filename alone discloses the theme. | `11:7,22,52` |
| L8 | Case-insensitive APFS: verified the volume collapses `Abc` and `abc`. Since the slug is lowercased, the short id is the sole differentiator, so a mixed-case id alphabet lets two passages name the same directory and `mkdir -p` merges them silently. | `02:39,43` |
| L9 | `xcrun --show-sdk-path` floats across five installed SDKs spanning macOS 15 and 26. Mitigated by the pinned `-target`, which I verified genuinely enforces availability. | `build.sh:24` |
| L10 | No probe script exists in the plan's file listing, yet four items begin with "write a probe" and probes are non-trivial because they must pump the run loop. | `02:14`, `build.sh:42-44` |
| L11 | A 5,000-word single "sentence" would make the alignment table 25 million cells. The tokenizer itself is fine — measured 6 ms for 50,000 words. | `09:85`, `10:51-52` |

---

## Assumptions audit

The user requested this explicitly. Twenty-seven factual claims were extracted and classified.

### Verified — independently re-confirmed

Fourteen of fourteen independently checkable claims in the environment table held up.

| Claim | Result |
| --- | --- |
| Xcode absent, Command Line Tools only, SDK 26.5 | Confirmed |
| Swift 6.3.3 | Confirmed |
| `-swift-version 6` compiles the declared view stack | Confirmed, zero diagnostics |
| macOS 14 APIs available at a macOS 14 target | Confirmed; availability checking proven genuinely enforced |
| `NLTokenizer` keeps the Dr. Smith sentence as one | Confirmed, count 1 |
| `supportsOnDeviceRecognition` true for en-US | Confirmed |
| 41 English voices, every one lowest tier | Confirmed exactly |
| 9 word callbacks for a 9-word sentence | Confirmed exactly |
| Silent synthesis yields 22050 Hz mono | Confirmed, non-interleaved |
| Synthesis needs a live run loop | Confirmed |
| `AVAudioSession` unavailable on macOS | Confirmed, compile error |
| XCTest unavailable | Confirmed, absent from Command Line Tools |
| Foundation has no zip API, `ditto` required | Confirmed, `AppleArchive` absent from the SDK |
| The prescribed delegate-shim shape compiles under strict concurrency | Confirmed, one warning, zero errors |

### Plausible — consistent with documentation, unchecked here

Two-player start skew of 10 to 50 ms; the encoder settings producing a valid `.m4a` and the
sample-rate key being ignored when passed as `Int`; UTF-16 offsets from the word-range
callback; ad-hoc signing producing a valid bundle. None testable without playing audio or
having source to build.

### Unverified or risky — and several are load-bearing

| Claim | Verdict |
| --- | --- |
| `openssl pkcs12 -legacy` works with the system openssl | **False.** LibreSSL 3.3.6 rejects it. See C2. |
| `tccutil reset` works for this bundle id | **False today.** OSStatus −10814, exit 64. |
| swift-testing unavailable | **False.** See C3. |
| **A self-signed certificate makes TCC grants survive rebuilds** | **Unverified and the single most load-bearing claim in the plan.** `security find-identity -v -p codesigning` returns **0 valid identities** — the certificate does not exist yet. Confirming it needs build, launch, grant, rebuild, re-check, which cannot happen before code exists. The entire development workflow and all of item 05's checklist rest on it. |
| **Ava 479 MB and Tom 411 MB Premium are obtainable** | **Unverified and load-bearing.** None installed. The 28 installed en-US voices are Samantha plus novelty voices. Sizes and tier labels cannot be checked without downloading, yet "Ava does not sound robotic" is item 04's stated acceptance test and voice quality is called the point of the app. |
| A single recognition request caps near 60 seconds | Unverified, hedged in the plan's own wording, load-bearing for the chunking design and the 45-second threshold. |
| The 60-line runner "was verified working before the plan was written" | **Unverifiable — the artifact does not exist.** Moot given C3. |
| `supportsOnDeviceRecognition` as a general property | Risky as generalized. True for en-US only. See M2. |

**Fastest validation plan.** Two actions close most of the risk in under an hour. First,
install Ava through System Settings and re-run a voice enumeration, recording the observed
identifier, language tag, and quality value — if Ava does not appear as premium, item 04 needs
rethinking before any code is written. Second, once item 01 produces a signed app, complete the
build, launch, grant, rebuild, re-check loop immediately and record the result, because every
later item assumes it. The recognition duration cap can be settled with one long recording
during item 08's probe.

---

## Edge case risk matrix

Ranked by impact times likelihood.

| # | Scenario | Likelihood | Impact | Risk | Component | Reference |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `codesign` fails, `\|\| true` swallows it, build reports success, microphone silently returns nothing | High | High | **CRITICAL** | build script | `build.sh:62-64` |
| 2 | `make-cert.sh` dies silently on LibreSSL, stderr discarded, fallback text unreachable | High | High | **CRITICAL** | signing setup | `make-cert.sh:36-39` |
| 3 | A delegate never fires; the exclusive-activity binding disables every control; app hangs until force quit, losing the in-flight take | Med | High | **CRITICAL** | all audio services | `06:56-65` |
| 4 | iCloud Documents sync evicts audio or forks `passage.json` into a conflict duplicate | Med | High | **HIGH** | PassageStore | `00:25`, `03:48-54` |
| 5 | Paragraph splitter contradicts its own spec; item 02 cannot satisfy both | High | Med | **HIGH** | SentenceSplitter | `02:31` vs `02:77-78` |
| 6 | Over-insertion or empty reference yields NaN, −∞, or −25% shown as a trusted score; NaN traps sort at `-Onone` | Med | High | **HIGH** | Scorer | `09:51-52,82-83` |
| 7 | Two instances race read-modify-write on `passage.json`; takes silently lost, audio orphaned | Med | High | **HIGH** | PassageStore | `03:34`, `build.sh:36-68` |
| 8 | Force quit, crash, or sleep mid-recording leaves a header-less `.m4a` already referenced by JSON | Med | High | **HIGH** | AudioRecorderService | `06:46-53` |
| 9 | A same-user process forges the code identity via the `-A` key ACL and inherits the microphone grant | Low | High | **HIGH** | signing setup | `make-cert.sh:42-45` |
| 10 | Title slugs to empty, giving a double hyphen and an unidentifiable folder | Med | Med | **HIGH** | Paths | `02:37-43` |
| 11 | A silent failure occurs and there is no log, no diagnostic, and raw error text is forbidden in the UI | High | Med | **HIGH** | everywhere | `12:51,68` |
| 12 | Audio deleted or moved by the user; playback, A/B, and re-score all throw with no defined presentation | Med | Med | **MED-HIGH** | player, scorer | `02:68`, `07` |
| 13 | Disk fills mid-recording; take lost despite the never-discard rule | Low | High | **MED-HIGH** | recorder, store | `06:27-42` |
| 14 | Input device removed mid-recording (AirPods); recorder halts without the finish delegate | Med | Med | **MED-HIGH** | recorder | `00:50`, `06` |
| 15 | 500-character title exceeds the 255-character component limit; verified 256 fails | Low | High | **MED-HIGH** | Paths, Export | `02:42` |
| 16 | Item 04 acceptance gated on an unverified 479 MB manual download the app cannot trigger | Med | High | **MED-HIGH** | ReferenceVoice | `04:91-92` |
| 17 | Confidence is uniformly 0.0 on device, so every take trips "hard to hear" and no score ever shows | Med | Med | **MED** | Scorer | `09:88-98` |
| 18 | 22050 Hz reference versus 44100 Hz takes fed to buffer recognition, producing gibberish scored as bad pronunciation | Med | Med | **MED** | TranscriberService | `00:48` vs `06:31` |
| 19 | Recognizer locale unpinned; en-GB has no on-device model and fallback is forbidden, so scoring vanishes | Low | High | **MED** | TranscriberService | `08:61-63` |
| 20 | Passage deleted or edited while scoring in flight; uncovered error or a score disagreeing with its own snapshot | Med | Med | **MED** | PracticeController | `03:46` |
| 21 | First schema change renders the whole library permanently "broken" with no migrator | Low | High | **MED** | PassageStore | `02:58-59` |
| 22 | Non-English paste produces a confident zero score the honesty constraint cannot catch | Low | Med | **MED** | Scorer | `02:79` |
| 23 | NUL or control characters inflate sentence count, persist in JSON, and void file URLs to empty | Low | Med | **MED** | Splitter, Paths | `02:24-33` |
| 24 | `tccutil` recovery errors in exactly the wedged state it is documented for | Med | Low | **MED** | dev loop | `build.sh:12-14` |
| 25 | A later item silently breaks an earlier one; nothing enforces the suite | Med | Med | **MED** | whole project | `10:69`, `12:72` |
| 26 | Export to a full or read-only volume leaves a partial zip and no message | Low | Med | **LOW-MED** | ExportService | `11:44-52` |
| 27 | Certificate expiry at 3650 days creates a duplicate CN and ambiguous signing, masked by risk 1 | Low | Med | **LOW-MED** | signing | `make-cert.sh:21-29` |
| 28 | Mixed-case short id collides on case-insensitive APFS; `mkdir -p` merges two passages | Low | Med | **LOW-MED** | Paths | `02:39` |
| 29 | Formula injection in a shared `scores.csv` evaluates in a recipient's spreadsheet | Low | Low | **LOW** | ExportService | `11:35-41` |
| 30 | Floating SDK symlink across five installed SDKs; builds not reproducible across toolchain updates | Low | Low | **LOW** | build script | `build.sh:24` |

---

## What the plan genuinely gets right

Worth not regressing. All five agents independently praised the same things.

- **The three-way honest labelling of verification style.** Every item declares whether it is
  test-first, probe-first, or checklist-verified, with reasons, and the overview states outright
  that "being honest about this matters more than making every item look like TDD" and "never
  claim an item is done because it compiles". Most plans blur that line. This one draws it.
- **The Foundation-only Core rule.** Named as the enabling constraint for a fast permission-free
  test loop, with the consequence stated. Four agents called this the single best decision in the
  plan; it is what makes findings C4, H20, and M10 cheap to act on.
- **Certificate and bundle before any code touches the microphone**, with the non-obvious reason
  stated: an ad-hoc signature makes the grant key on the binary hash, and the failure is sometimes
  a silent denial indistinguishable from an encoder bug.
- **Permissions before the recorder**, justified by defect isolation. The same principle is applied
  consistently at transcript-before-score.
- **The scorer design.** Global alignment with backpointers, explicitly rejecting greedy matching
  and longest common subsequence with the right justification; deliberately asymmetric costs with
  an empirical reason and a flagged tuning knob; an instruction not to optimize the quadratic
  implementation. Called the strongest single item in the plan.
- **The two honesty constraints.** Low confidence presents as hard-to-hear rather than a red score,
  and the label reads as words recognized rather than a pronunciation grade. Correctly marked as
  requirements, not polish.
- **Item 08's error-presentation table.** Names an exact error identity rather than gesturing at
  "recognition errors", and forbids the two behaviors an implementer would otherwise default to.
- **Item 05's degradation table.** The app stays useful in every permission state, including the two
  usually skipped: offline-model-unavailable and revocation after a grant.
- **Atomic saves, Trash-based deletion, corrupt-file isolation, and no index file.** Four correct
  persistence decisions, each with the right reason attached. Findings C7, H9, and H17 argue the
  discipline was not carried far enough, not that it is wrong.
- **Two mechanical rules that eliminate error classes rather than instances.** UTF-16 offset
  conversion with the explicit warning that character-array slicing drifts on accents, and mapping
  non-Sendable Speech types to value types inside the closure. The claim that the second
  "eliminates the entire class of Swift 6 errors here" is accurate.
- **One sentence per utterance**, so word-highlight ranges stay local and paragraph highlighting
  becomes two-level rather than a new mechanism. The plan's most elegant insight.
- **Relative `audioPath` and per-take `referenceText` snapshots**, each stated with its future
  debugging symptom. Writing the future debugging session into the plan is a practice worth keeping.
- **Zero third-party dependencies and no network calls in the build.** For a non-sandboxed app with
  a microphone grant this is worth more than most hardening measures.
- **Certificate constraints are minimal and correct** — `CA:false`, `digitalSignature`,
  `codeSigning`, all critical — and the certificate is never added to a trust store. Many
  local-signing guides get both wrong.
- **`tccutil` is correctly scoped to the bundle identifier** in both places it appears. Omitting it
  resets every app on the machine.

---

## Executive summary

**Verdict.** This is a strong plan with a weak foundation. The design thinking is better than
most shipped code: the scorer, the persistence decisions, the permission degradation table, and
the honest labelling of what is actually tested are all things experienced engineers usually get
wrong. But the plan's quality strategy rests on a factual claim that is false, its development
workflow rests on a claim that is unverified, and the two shell scripts that implement that
workflow both fail silently. The gap is systematic rather than local: where the plan encountered a
failure mode during exploration it handles it unusually well, and it is silent on nearly every
failure mode it did not happen to meet. The biggest single risk is that a suppressed shell error
in `build.sh` presents as a dead microphone two work items later, sending the developer to debug
the recorder while the actual cause is four lines of shell written before any Swift existed.

**Top three actions.**

1. **Fix the two shell scripts, then verify the certificate claim end to end.** Stop swallowing
   `codesign` status, resolve openssl explicitly and fail loudly, drop `-A` and add `-x` on the key
   import, and add `--options runtime`. Then actually complete the build, launch, grant, rebuild,
   re-check loop and record the result. Everything in the plan's development workflow assumes this
   works and nothing has demonstrated it. About half a day, and it removes the two CRITICAL risks
   at the top of the matrix.
2. **Adopt swift-testing and re-scope the test target.** The hand-rolled runner is unnecessary, and
   deleting it also deletes the bootstrap problem, the manual test-registration step, and the
   silent-false-negative risk that is the plan's largest hidden hazard. In the same pass, fix the
   rule so the store and the export logic are actually compiled by the test target, since those
   hold the two tests the plan itself calls most important. Under a day, and it changes what item
   02 builds, so it must happen before item 02 starts.
3. **Close the four schema and contract decisions that are expensive after item 02.** Pin
   `TargetRef.id` as a stable UUID; add the transcript type with confidence that the scorer needs
   and the model list omits; clamp accuracy to zero-to-one and define the empty-reference contract;
   and resolve the paragraph-splitter contradiction. All four are cheap now and all four are baked
   into the on-disk format or the public contract the moment item 02 ships.

**Confidence.**

| Recommendation | Confidence | What would raise it |
| --- | --- | --- |
| Fix `build.sh` status handling | **High** | Nothing. Reproduced directly; the plan's own checklist cannot pass as written. |
| Fix `make-cert.sh` openssl resolution | **High** | Nothing. Verified LibreSSL rejects the required flag. |
| Adopt swift-testing | **High** | Nothing. I built and ran a suite with correct exit codes. Residual risk is future toolchain path changes, which fail at compile time. |
| Re-scope the test target | **High** | Nothing. The contradiction is textual. |
| Clamp accuracy, define empty reference | **High** | Nothing. The arithmetic was measured at −4.0 and −∞. |
| Paragraph splitter contradiction | **High** | Nothing. Traced against the plan's own table. |
| Delegate timeouts | **Medium-High** | Which callbacks actually fail to fire on this hardware; only item 06's probe can tell. |
| iCloud handling | **Medium** | Whether the user will ever enable Desktop and Documents sync. Confirmed off today, one toggle away. |
| One file per take instead of one document | **Medium** | Real measurements of `passage.json` growth after a month of daily practice. Directionally sound; the threshold is unknown. |
| Add a preferences layer | **Medium-High** | Whether voice is app-wide or per-passage. Currently undecided in the plan. |
| Fifty labelled scoring fixtures | **Medium** | Whether the user will actually do the unglamorous labelling. The methodological criticism is correct; the prescribed volume is a judgement call. |
| Hardened runtime | **Medium-High** | Confirming no dyld complaint once there is a real bundle to sign. |
| Item 09 re-sequencing | **Medium** | This trades motivation against rigor. The schema argument for moving it is strong; the demo-later cost is real for a solo project. |

**Paranoid verdict.** The scariest thing found is the interaction between `build.sh:62-64` and
the entire privacy-grant premise the project is built on. The plan's load-bearing claim is that a
stable self-signed certificate makes microphone grants survive rebuilds. There are currently zero
valid code-signing identities on this machine, and both paths to establishing one are broken:
`make-cert.sh` dies without a word because the system openssl rejects the flag that macOS's own
import tool requires, and if the certificate is absent or signing fails for any other reason,
`build.sh` swallows the error and prints success. The result installs cleanly, launches cleanly,
and its microphone returns nothing with no dialog and no error. A developer hitting this would
spend an afternoon inside the recorder, the permission service, and the usage strings, because
every symptom points at the recorder. The plan's own reasoning is exactly right that bundle
mechanics debugged under a half-written app take an afternoon because every symptom looks like an
application bug. These two defects are what make that come true anyway. Both are a handful of
lines, right now, before a single Swift file exists.

---

## Fixing Plan

Every item traces to a finding above. Nothing invented.

### Phase 1: Critical fixes — before any Swift is written

**1. Stop `build.sh` swallowing codesign failures** (C1)
- **Fix**: Capture output into a variable, test the exit status, filter only for display, exit
  non-zero on failure. Apply to both the sign and verify steps. Gate the `ditto` install on
  verification passing. Add an assertion that the signature is not ad-hoc when a certificate is
  expected.
- **Effort**: `[< 1 day]`
- **Files**: `build.sh`

**2. Make `make-cert.sh` fail loudly and resolve openssl explicitly** (C2)
- **Fix**: Resolve openssl into a variable, preflight for `pkcs12 -legacy` support, print the
  Keychain Access fallback on failure. Remove `2>/dev/null` from both openssl calls. Extend the
  trap to `EXIT INT TERM HUP`.
- **Effort**: `[< 1 day]`
- **Files**: `make-cert.sh`

**3. Harden the key import and the signature** (H5, H24, L3)
- **Fix**: Drop `-A`, drop the redundant `-T /usr/bin/security`, add `-x` for non-extractability.
  Add `--options runtime` to `codesign`. Use `grep -c -F` and assert exactly one matching identity.
- **Effort**: `[< 1 day]`
- **Files**: `make-cert.sh`, `build.sh`

**4. Adopt swift-testing and correct the plan's claims** (C3)
- **Fix**: Write `test.sh` compiling `-framework Testing` with the verified flags, pinning the three
  toolchain paths in one variable with a fail-loudly guard. Delete the hand-rolled runner from item
  02's deliverables. Correct the overview's testing rows and the claim that the runner was verified.
- **Effort**: `[< 1 day]`
- **Files**: `test.sh` (new), `docs/plan/00-overview.md`, `docs/plan/02-core-models-and-naming.md`

**5. Re-scope the test target so the store and export logic are testable** (C4)
- **Fix**: Restate the rule as governing the test target's import closure. Move `PassageStore` into
  the compiled-by-tests tree; split `ScoreCSV` and `ExportNaming` out of `ExportService`. Add an
  import-allowlist check to both `test.sh` and `build.sh` so the rule cannot drift (M7).
- **Effort**: `[< 1 day]`
- **Files**: `docs/plan/00-overview.md`, `03-store-and-first-screen.md`, `11-export.md`, `test.sh`, `build.sh`

**6. Add a logging layer and amend the no-raw-errors rule** (C5)
- **Fix**: Add a Foundation-only `Log.swift` to item 02 with per-subsystem loggers and the rule that
  every catch logs the full error. Add "Copy diagnostics" to item 12's menu. Amend item 12 to forbid
  raw errors in the UI only.
- **Effort**: `[< 1 day]`
- **Files**: `docs/plan/02-core-models-and-naming.md`, `12-polish.md`

**7. Put deadlines in the delegate shim contract** (C6)
- **Fix**: Specify the timeout budgets in item 06 as part of the shim, scaled to audio duration, with
  the on-timeout behavior: resume with error, log, reset to idle, import partial audio. Add done-when
  rows for device loss and a stalled recognition asset.
- **Effort**: `[< 1 week]`
- **Files**: `docs/plan/06-recorder.md`, `07-player-and-ab.md`, `08-transcription.md`

**8. Decide and document the iCloud position** (C7)
- **Fix**: Either detect the ubiquitous case, coordinate file access, and handle dataless files; or
  state sync-off as a hard prerequisite in the README and the overview. Add a done-when row either way.
- **Effort**: `[< 1 day]` documented, `[< 1 week]` handled
- **Files**: `docs/plan/00-overview.md`, `03-store-and-first-screen.md`, `README.md`

**9. Validate the two load-bearing unverified assumptions** (assumptions audit)
- **Fix**: Install Ava, re-enumerate voices, record the observed identifier and quality value in the
  overview replacing the unverified sizes. Complete the build, launch, grant, rebuild, re-check loop
  as the first act of item 01 and record the result.
- **Effort**: `[< 1 day]`
- **Files**: `docs/plan/00-overview.md`, `01-bundle-and-signing.md`, `04-reference-voice.md`

### Phase 2: High-priority — settle before or during item 02

**10. Clamp accuracy and define the degenerate contracts** (H1)
- **Fix**: Guard zero-length reference with a distinct non-numeric outcome; clamp to zero-to-one;
  store the raw weighted error separately so the over-insertion signal survives; assert the bound over
  randomized inputs; assert the status counts sum to the reference length.
- **Effort**: `[< 1 day]` · **Files**: `docs/plan/09-normalizer-and-scorer.md`

**11. Resolve the paragraph splitter contradiction** (H2)
- **Fix**: Normalize line endings first, split on two-or-more newlines, delete the fallback, correct
  the table row, add CRLF rows.
- **Effort**: `[< 1 day]` · **Files**: `docs/plan/02-core-models-and-naming.md`

**12. Pin `TargetRef.id` and add the transcript type** (H11, M10)
- **Fix**: `TargetRef.id` is a stable UUID minted at split time; whole-passage uses the passage id;
  the CSV target index is derived at export, never stored. Add `Transcript` and `TranscriptWord` with
  confidence to the item 02 model list. Decide transcript persistence fidelity (H9).
- **Effort**: `[< 1 day]` · **Files**: `docs/plan/02-core-models-and-naming.md`, `08`, `09`, `11`

**13. Make the store API delta-shaped and fix the concurrency test** (H10, H8)
- **Fix**: Remove whole-document save from the public API; expose append and update-score that read
  inside the actor. Rewrite the concurrent-append test to append from a stale cached copy. Restate the
  filesystem invariant precisely: the store owns layout, JSON, and file creation; services read and
  write bytes only at URLs the store vends.
- **Effort**: `[< 1 day]` · **Files**: `docs/plan/03-store-and-first-screen.md`

**14. Split the activity enum** (H7)
- **Fix**: Keep an exclusive audio axis and add an in-flight set for scoring and baking. Must come
  after item 13.
- **Effort**: `[< 1 day]` · **Files**: `docs/plan/06-recorder.md`

**15. Add a single-instance lock and conditional writes** (H3)
- **Fix**: `flock` on a library lock file at launch; record the modification date at read and abort-and-
  reload if it moved before replacing. Add a second-writer test row.
- **Effort**: `[< 1 day]` · **Files**: `docs/plan/03-store-and-first-screen.md`

**16. Replace the termination rescue with a staging directory** (H4)
- **Fix**: Record into an `incoming/` directory; move into place and write the take entry only after
  the finish delegate. Scan `incoming/` on launch and adopt or quarantine. Observe sleep notifications.
  Reword the guarantee to "never silently discarded" and test force quit and sleep.
- **Effort**: `[< 1 week]` · **Files**: `docs/plan/06-recorder.md`, `03-store-and-first-screen.md`

**17. Add the preferences layer** (H6)
- **Fix**: An observable settings type over `UserDefaults` holding voice, rate, banner-seen, and last
  selection, hung off the app model in item 03. Decide that voice and rate are app-wide.
- **Effort**: `[< 1 day]` · **Files**: `docs/plan/03-store-and-first-screen.md`, `00-overview.md`

**18. Add a unified error type** (H15, H12, H13, H16, H17)
- **Fix**: One Foundation-only failure enum in item 02 carrying an underlying error and a user message,
  with cases covering denial, missing model, no speech, recorder start failure, device loss, out of
  space, library unavailable, corrupt passage, missing audio, schema mismatch, export failure, and
  timeout. Add a test asserting every message is one actionable sentence with no raw error text.
- **Effort**: `[< 1 week]` · **Files**: `docs/plan/02-core-models-and-naming.md`, all service items

**19. Handle missing audio, disk-full, device loss, and export failure** (H12, H13, H14, H16)
- **Fix**: Stat audio on scan and set a flag; disable play, A/B, and re-score for takes without audio.
  Preflight capacity before arming the recorder and before export. Observe default-input-device changes
  and act on a sustained floor-level meter reading. Check the subprocess exit status, clean up partial
  archives, and route the scores file through the store's atomic write. Make export mutually exclusive
  with recording.
- **Effort**: `[< 1 week]` · **Files**: `06-recorder.md`, `07-player-and-ab.md`, `11-export.md`, `03-store-and-first-screen.md`

**20. Add repair and migration** (H17)
- **Fix**: Broken summaries carry the folder URL and offer reveal and trash on the raw URL; copy a bad
  file aside before any overwrite; declare a migration policy with a decode-old-fixture test; add an
  orphan sweep.
- **Effort**: `[< 1 week]` · **Files**: `docs/plan/03-store-and-first-screen.md`, `02-core-models-and-naming.md`

**21. Fix the slug specification and its tests** (H21, M6, M13, L8)
- **Fix**: Positive whitelist, non-empty fallback, transliteration before giving up, a 255-character cap
  on the assembled component truncating on a hyphen boundary, lowercase id alphabet, and a control-
  character assertion. Add rows for traversal, leading dot, leading hyphen, punctuation-only, CJK-only,
  500 characters, and NUL.
- **Effort**: `[< 1 day]` · **Files**: `docs/plan/02-core-models-and-naming.md`, `11-export.md`

**22. Name the scoring thresholds and add the confidence fallback** (H22)
- **Fix**: Name the similarity function and both confidence thresholds; specify behavior in all four
  quadrants; add a probe assertion that per-segment confidence is non-zero and varying, with a metering-
  based fallback if it is not; fill the empty test cell.
- **Effort**: `[< 1 day]` · **Files**: `docs/plan/09-normalizer-and-scorer.md`, `08-transcription.md`

**23. Commit fixtures and split invariant tests from calibration tests** (H18)
- **Fix**: A fixtures directory with hand-labelled expected flagged words; roughly fifty takes across
  clean, substitution, skip, insertion, mumbled, and long categories; a held-out split; an acceptance
  metric defined before tuning.
- **Effort**: `[< 1 week]` · **Files**: `docs/plan/08-transcription.md`, `09-normalizer-and-scorer.md`

**24. Initialize git, add a pre-commit hook, and require the suite everywhere** (H19)
- **Fix**: `git init`, a hook running `test.sh`, "the suite passes" in every item's done-when, and a
  golden-file naming test so a slug change fails loudly.
- **Effort**: `[< 1 day]` · **Files**: all plan items, `.git/hooks/pre-commit`

**25. Move testable logic into the test target** (H20)
- **Fix**: Relocate the audio state machine, chunk planning and timestamp offsetting, range conversion,
  the permission matrix, voice tier ranking, the encoder settings assertion, and the decibel conversion,
  behind protocols where a framework object is involved.
- **Effort**: `[< 1 week]` · **Files**: `04`, `05`, `06`, `08`, `00-overview.md`

**26. Decide the passage-editing question** (H23)
- **Fix**: Either declare text immutable after the first take, move it to out-of-scope, delete the
  misleading justification, and offer duplicate-with-edited-text; or add stable sentence ids and a
  re-match step. Recommend the first, with stable ids added regardless.
- **Effort**: `[< 1 day]` for the first option · **Files**: `02-core-models-and-naming.md`, `00-overview.md`, `12-polish.md`

### Phase 3: Medium-priority

27. Language hint on paste, and refuse to score text with no scorable tokens (M1) `[< 1 day]`
28. Pin the recognizer locale to en-US and name it in the offline-model copy (M2) `[< 1 day]`
29. Add an explicit format-conversion boundary before buffer recognition (M3) `[< 1 day]`
30. Cancel or invalidate in-flight scoring on delete and edit, via a passage revision (M4) `[< 1 day]`
31. Annotate the expected `tccutil` error and give the real fallback (M5) `[< 1 day]`
32. Sanitize control characters and normalize line endings at intake (M6) `[< 1 day]`
33. Introduce derived row summaries so row rendering is constant-time (M8) `[< 1 day]`
34. Re-frame item 10 honestly and budget the utterance sequencer into item 04 (M9) `[< 1 day]`
35. Re-sequence: split item 09 into build and tune, move the build half early (M10) `[< 1 day]`
36. Add CSV rows for newlines, formula injection, encoding, and export-name collision; specify argument-array invocation (M11, L6) `[< 1 day]`
37. Add store error-path and user-edited-folder tests (M12) `[< 1 day]`
38. Fix the naming test assertions: byte cap, timezone, every date field, take-filename collision, all schema-version cases (M13) `[< 1 day]`
39. Make both subjective gates falsifiable underneath, keeping the human sign-off (M14) `[< 1 day]`
40. Write `run.sh`, or mark it aspirational, and correct the runner-verified claim (M15) `[< 1 day]`
41. Resolve the third-requirement collision with the user (M16) `[< 1 day]`

### Phase 4: Low-priority cleanup

Grouped by file so a single visit clears them.

- **`build.sh`**: quote source paths via a NUL-delimited array and drop the shellcheck suppression (L4); warn loudly on ad-hoc mode and give it a separate bundle id and path (L2); echo the resolved SDK and version (L9).
- **`make-cert.sh`**: extend the trap to interrupt signals (L5); print and persist the identity hash so signing is unambiguous (L3, risk 27).
- **`docs/plan/04-reference-voice.md`**: declare a banner kind enum with a precedence order and a single owner (L1); match voices on identifier rather than localized display name.
- **`docs/plan/02-core-models-and-naming.md`**: add `probe.sh` and a shared run-loop helper to the deliverables (L10).
- **`docs/plan/09-normalizer-and-scorer.md`**: cap token count for a single target (L11).
- **`docs/plan/11-export.md`**: add a transcripts-only export variant (L7).

### Dependency graph

- Fix 5 (test target scope) depends on Fix 4 (swift-testing) — the compile invocation changes.
- Fix 14 (split the activity enum) depends on Fix 13 (delta-shaped store) — splitting the enum permits concurrent scoring, which multiplies the mutation sources Fix 13 exists to make safe. Reversing the order converts a responsiveness fix into silent data loss.
- Fix 16 (staging directory) depends on Fix 13 — it changes when the take entry is written.
- Fix 19 (missing audio, disk full, export) depends on Fix 18 (unified error type) — it needs cases to throw.
- Fix 22 (confidence fallback) depends on Fix 9's probe result — the fallback is only needed if confidence is unusable.
- Fix 17 (preferences) is required by the banner-dismissed flag in L1.
- Fixes 10, 11, 12, 21 must all land before item 02 ships, since each is baked into the on-disk format or a public contract.
- Fix 9 (validate assumptions) should precede everything in Phase 2, because a negative Ava result changes item 04's design.

### Estimated total effort

| Phase | Effort |
| --- | --- |
| Phase 1 | 3 to 4 days |
| Phase 2 | 8 to 10 days |
| Phase 3 | 4 to 5 days |
| Phase 4 | 1 to 2 days, opportunistic |
| **Total** | **16 to 21 days** |

Phase 1 is the only phase that genuinely blocks starting. Most of Phase 2 is plan edits rather
than code, and lands naturally inside items 02 and 03.
