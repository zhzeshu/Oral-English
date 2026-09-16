# 06 — Permissions

**Status:** PARTIAL — corrected 2026-09-15. Was stamped DONE on 2026-09-14; that stamp
was **wrong**. The recognition request path crashed every time it ran, so the five gates
recorded as "BLOCKED on the user" were not blocked on the user at all — see
**The crash this stamp was hiding** below. The crash is now fixed and the recognition
grant is verified end to end; the remaining gates genuinely do need a human.
**Changed:** Sources/Core/PermissionMatrix.swift, Sources/Core/BannerKind.swift,
Sources/Services/PermissionService.swift, Sources/App/AppModel.swift,
Sources/Views/RootView.swift, Sources/Tools/PermissionProbe.swift,
Tests/PermissionMatrixTests.swift
**Verified:** ./test.sh (261 tests in 21 suites passed as of 2026-09-15, including all 75
combinations of the matrix), ./build.sh clean, ./probe.sh PermissionProbe, and — new on
2026-09-15 — a real speech-recognition grant obtained through
`PermissionService.requestRecognition()` and persisted (`speech recognition: granted`).
**Blocked gates:** granting and denying permissions needs a human clicking in System
Settings. The decision logic is fully tested; the dialogs are not.

**Verification style:** checklist, exercised by actually denying things. The degradation
matrix itself is a pure function and is unit-tested.

## Goal

Microphone and speech-recognition authorization, requested at the right moment, with
graceful degradation when refused.

## Why this comes before the recorder

Built in this order, a misbehaving recorder can be diagnosed. Built the other way round,
every recording failure has two possible causes and no way to tell them apart. Half an hour
here saves an afternoon in item 08.

## Files

- `Sources/Core/PermissionMatrix.swift` — pure, unit-tested
- `Sources/Services/PermissionService.swift`
- `Sources/Views/BannerView.swift`
- `Tests/PermissionMatrixTests.swift`

## Red — the matrix is a pure function

Revision 1 left this as a four-row table verified by hand. It is
`(mic, recognition, offlineModel) -> (canRecord, canScore, banner)`, so it belongs in the
test target. Nobody will re-test the granted-then-revoked transition by hand in month three.

Assert every combination, including: both granted; mic denied; recognition denied; both
denied; mic granted and offline model unavailable; and each state after having previously
been granted.

## Green

`PermissionService` exposes the two states and requests each lazily. `refresh()` reads
current status without touching hardware, so it is safe at launch.

- Microphone: `AVAudioApplication.requestRecordPermission`, available on macOS 14 and
  verified present in this SDK.
- Recognition: `SFSpeechRecognizer.requestAuthorization`, whose callback arrives off the
  main thread, so wrap it in a continuation and hop.

Do **not** reach for `AVAudioSession`; it does not exist on macOS and will not compile. Note
that its absence also means route-change and interruption events must come from Core Audio
or `AVCaptureDevice` instead — item 08 needs that, and revision 1 mistook a missing API for
a missing problem.

**Request on the first record tap, never at launch.** A cold prompt with no context is the
main reason people press Deny, and a denial is expensive to undo.

## Degradation rules

Requirements, not nice-to-haves. The app stays useful in every state.

| State | Behavior |
| --- | --- |
| Microphone denied | Record disabled with an explanation. Reference playback and playback of existing takes keep working |
| Recognition denied | Recording and A/B keep working fully. Scoring is marked off with a link to enable it |
| Recognition granted, offline model unavailable | Explain that scoring needs the offline **en-US** model. **Never** silently fall back to server recognition; local-only was a requirement |
| Either denied after being granted | The banner reappears and the affected control explains itself rather than failing silently |

The recognition-denied path keeps the app usable while fighting privacy grants during
development, so build it properly rather than stubbing it.

## The banner

Declare a `BannerKind` enum with an explicit priority order: permission denied, then offline
model missing, then voice quality. A single computed `banner` on the app model derives from
state. Permission kinds are never dismissible; the voice-quality kind is dismissible once and
thereafter lives in the menu, which is what the settings flag from item 04 is for.

Revision 1 had four items writing to one banner with no owner and no precedence, and
specified its lifetime twice inconsistently — so a dismissed voice nag could hide a permission
problem. Keep the transient no-speech-heard message out of the banner entirely; it belongs
inline with a re-record button.

## Done when

- [x] `./test.sh` passes, including every matrix combination.
- [~] *(PARTIAL, 2026-09-15)* The **recognition** prompt is verified: it appeared, was
      granted, and the grant persisted. The microphone half is still unverified in the app,
      and a probe cannot stand in for it (item 08 established that a probe cannot obtain a
      microphone grant by any route). Needs one record tap in the real app.
- [ ] *(BLOCKED on the user)* Denying the microphone and relaunching shows the banner and a disabled record control,
      and reference playback still works.
- [ ] *(BLOCKED on the user)* Denying only recognition leaves recording and A/B fully working.
- [ ] *(BLOCKED on the user)* Each banner button opens the correct Privacy pane.
- [ ] *(BLOCKED on the user)* Granting a permission and returning clears the banner without a relaunch.
- [x] Nothing prompts at launch.
- [x] A permission problem is visible even when the voice banner has been dismissed.
- [ ] *(BLOCKED on the user)* After a rebuild the grants are still in place. If not, the certificate is not being
      used; check `codesign -dv`.


## What the probe found

The reviewer's warning about locales is confirmed exactly:

```
microphone:            notDetermined
speech recognition:    notDetermined
offline en-US model:   available

on-device recognition by locale:
  en-US: available=true onDevice=true
  en-GB: available=true onDevice=false
  en-AU: available=true onDevice=false
  zh-CN: available=true onDevice=false
```

So a naive `isAvailable` check passes for three locales that have **no on-device model**,
and since there is deliberately no server fallback, any of them would leave scoring silently
unavailable. Pinning `en-US` is therefore load-bearing, not a convenience.

Also confirmed: constructing a recognizer for an unsupported locale writes
`No Assistant asset for language en-GB` to stderr. **Do not enumerate locales to build a
picker** — it spews into the system log for every one that lacks an asset.

Nothing prompts at launch: the probe reads `notDetermined` for both permissions without
producing a dialog, which is the behavior `refresh()` is designed for.

## The crash this stamp was hiding

Found 2026-09-15, while trying to answer item 10's confidence question.

`PermissionService.requestRecognition()` died with `SIGTRAP` on **every** invocation,
inside TCC's XPC reply callback:

```
dispatch_assert_queue_fail
  _swift_task_checkIsolatedSwift
  closure #1 in closure #1 in static PermissionService.requestRecognition()
  thunk for @escaping (SFSpeechRecognizerAuthorizationStatus) -> ()
  TCC __TCCAccessRequest_block_invoke
```

The class is `@MainActor`, and **that propagates to its `static` members**, so
`Self.map(status)` was main-actor isolated. `SFSpeechRecognizer.requestAuthorization`
delivers its completion on TCC's own queue, so Swift 6's executor check fired and trapped.
The closure's own comment shows the author knew the callback was off-main and mapped inside
it deliberately — the trap is that the type-level `@MainActor` silently captured the
statics too.

Fix: `nonisolated` on both `map` overloads. They are pure switches over enum cases, so they
are safe on any executor. One line each.

**Why this mattered more than a probe bug.** The real app calls the same method on the first
record tap, so it would have crashed there identically. This was an app defect wearing a
permissions costume.

**Why it looked like a denial.** The process died before any status could be stored, so TCC
recorded nothing and the status stayed `notDetermined` rather than becoming `denied`. Every
retry produced the same "DENIED" line, and `tccutil reset` had nothing to reset. The
distinction between `notDetermined` and `denied` after a request is the tell: a real refusal
persists, and this did not.

**Why the suite could not catch it.** `PermissionService.swift` imports `Speech`, so it
cannot be in the pure test target that `test.sh` compiles. 261 passing tests cannot see this
file. The crash reports had been sitting in `~/Library/Logs/DiagnosticReports/` since 09:27
that morning, unread — worth checking there before concluding that a privacy prompt was
refused.

**A second, smaller defect, same session.** `TranscribeProbe` called
`requestForRecording()`, which requests the microphone first and gates the recognition
request behind `microphone.isGranted`. But that probe transcribes a file from disk and never
opens the microphone, so it was blocking on a permission it does not use — and a probe
cannot get that permission at all. It now calls
`PermissionService.requestRecognition()` directly.
