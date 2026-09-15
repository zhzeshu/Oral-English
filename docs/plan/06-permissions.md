# 06 — Permissions

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

- [ ] `./test.sh` passes, including every matrix combination.
- [ ] First record tap prompts for the microphone, then recognition, with the Info.plist
      usage strings.
- [ ] Denying the microphone and relaunching shows the banner and a disabled record control,
      and reference playback still works.
- [ ] Denying only recognition leaves recording and A/B fully working.
- [ ] Each banner button opens the correct Privacy pane.
- [ ] Granting a permission and returning clears the banner without a relaunch.
- [ ] Nothing prompts at launch.
- [ ] A permission problem is visible even when the voice banner has been dismissed.
- [ ] After a rebuild the grants are still in place. If not, the certificate is not being
      used; check `codesign -dv`.
