# 07 — The reference voice

**Status:** DONE — 2026-09-14 (three gates BLOCKED on the user, see below)
**Changed:** Sources/Core/VoiceRanking.swift, Sources/Services/ReferenceVoice.swift,
AppleVoiceProvider.swift, VoiceCatalog.swift, DelegateShim.swift, PracticeController.swift,
Sources/App/AppModel.swift, Sources/Views/{SentenceRowView,PassageDetailView}.swift,
Sources/Tools/{VoiceProbe,BakeProbe}.swift, Tests/VoiceRankingTests.swift
**Verified:** ./test.sh (212 tests in 14 suites), ./build.sh clean,
./probe.sh VoiceProbe (65935 frames, 22050 Hz mono, 8 word callbacks for 8 words, ranking
selects Samantha), ./probe.sh BakeProbe (194 KB file, 47550 frames, 2.16 s, accepted by
AVAudioPlayer)
**Update 2026-09-14:** Ava (Premium) is installed. Identifier
`com.apple.voice.premium.en-US.Ava`, en-US, tier premium, 42 English voices now present.
Ranking selects it automatically and the banner is no longer warranted. A blind A/B
comparison is baked to the Desktop awaiting a verdict.
**Blocked gates:** the listening verdict itself, and watching the highlight track the
audio.

**Verification style:** probe-first, then judged by ear against a blind control. The tier
ranking is a pure function and is unit-tested.

## Goal

Per-sentence playback in a voice that sounds like a native American speaker rather than a
robot, with the spoken word highlighting as it goes.

## Prerequisite, before any code in this item

**Install a Premium voice and confirm it appears as Premium.** Ava and Tom are believed to be
Premium American English at roughly 479 MB and 411 MB, but neither is installed, the figures
are unverified, and this item's acceptance test depends on them. Run the enumeration probe
afterwards and record the observed name, language tag, identifier and quality value in the
overview, replacing the unverified sizes. If no Premium voice materializes, this item needs
rethinking before code is written, which is exactly the cheap moment to find out.

Obtainable American English voices, believed:

| Voice | Size | Tier |
| --- | --- | --- |
| Ava | 479 MB | Premium |
| Tom | 411 MB | Premium |
| Susan | 132 MB | Enhanced |
| Allison | 99 MB | Enhanced |

## Why this matters more than it looks

Every English voice currently installed is the lowest quality tier. That is the complete
explanation for the robotic sound, and no amount of code fixes it. Better voices are a free
download, the app cannot trigger that download itself, so clear guidance is the entire
available remedy.

## Files

- `Sources/Core/VoiceRanking.swift` — pure tier ranking and best-installed selection
- `Sources/Services/ReferenceVoice.swift` — the protocol
- `Sources/Services/AppleVoiceProvider.swift`
- `Sources/Services/VoiceCatalog.swift`
- `Sources/Tools/VoiceProbe.swift`
- `Tests/VoiceRankingTests.swift`

## Probe first

`./probe.sh VoiceProbe` must print every installed English voice with its quality tier, then
synthesize one sentence and report the frame count and the word-boundary callbacks received.

**The probe must pump the run loop.** A command-line tool has no run loop, and without one
`AVSpeechSynthesizer` silently produces zero frames and zero callbacks. Confirmed by
experiment: the same code returns nothing without a run loop and works correctly with one.
Do not conclude the API is broken. `probe.sh` provides a shared run-loop helper so each probe
does not re-derive it.

Passes when it reports a non-zero frame count and one callback per word.

## Red — tier ranking is testable

Revision 1 verified voice selection by ear only, so a change silently reverting to the system
compact voice would be inaudible to someone who has forgotten the baseline. Assert:

- Given a list containing a Premium voice, selection returns the Premium one.
- Given Enhanced but no Premium, returns Enhanced.
- Given only lowest-tier voices, returns one **and** signals that the banner is needed.
- Ranking is stable and prefers en-US among equal tiers.
- Selection never returns the system default when something better is installed.

## Green

`ReferenceVoice` is a small protocol: given text and a voice choice, produce audio, either
streamed for immediate playback or written to a file. `AppleVoiceProvider` implements it over
`AVSpeechSynthesizer`. Nothing else knows which provider it is talking to, so adding a neural
service later is one new file plus a picker entry.

The protocol carries a non-defaulted `dataLeavesDevice` requirement, so every future conformer
must state its answer and the compiler enforces it. Any provider answering true is off by
default, labeled in the picker, requires explicit one-time opt-in naming what is sent and to
whom, and can never be chosen by the best-installed default. Local-only is a hard requirement
enforced in three places on the recognition side; this puts the same guarantee in the type
system on the synthesis side, where revision 1 left only prose.

The synthesizer **must be a stored property**. A local one deallocates and speech stops
instantly.

`VoiceCatalog` checks on launch whether any installed English voice is above the lowest tier.
When none is, the banner explains in one sentence that the reference will sound robotic and
offers a button to the Spoken Content pane, with the three clicks needed: System Voice, Manage
Voices, tick Ava. The banner appears on first run and thereafter lives in the menu; a
permanent nag is worse than a robotic voice.

Match voices on **identifier, not display name**. Voice names are localized, so matching
"Ava" as a string fails on a non-English system UI.

Default to the best installed English voice, never the system default, because the system
default is the compact voice that started this problem. Speaking rate defaults slightly below
normal, since the reference exists to be imitated.

## The utterance sequencer

Speak **one sentence per utterance**, always, including at paragraph and whole-passage level.
That keeps highlight ranges local to a sentence and makes two-level highlighting fall out for
free later. It also means paragraph and whole playback need a sequencer that walks sentences
and maintains which sentence is active plus which word within it. **Build that here**, where
the one-sentence-per-utterance decision is made. Revision 1 deferred it implicitly to item 12
while calling that item nearly free.

## Word highlighting

`willSpeakRangeOfSpeechString` gives an `NSRange` in **UTF-16 offsets** into
`utterance.speechString`. Convert with `String.Index(utf16Offset:in:)`. Slicing with
`Array(text)[range]` is wrong and drifts on any accented character or emoji. Put the
conversion in `Core/` and unit-test it with accents and an emoji.

The callback may arrive off the main thread, so convert to plain integers and hop. A voice
that fires no range callbacks at all is a supported case, not a bug: degrade to highlighting
the whole sentence rather than appearing broken.

## Done when

- [x] **A Premium voice is installed** and its actual identifier and tier are recorded in
      the overview: `com.apple.voice.premium.en-US.Ava`, en-US, premium. Note this differs
      from the identifier the asset catalog advertises — see the findings.
- [x] The probe reports non-zero frames and at least one callback per word. *(Count is not exactly one per word — see findings.)*
- [x] `./test.sh` passes, including the ranking and range-conversion tests.
- [ ] *(BLOCKED on the user)* **Blind A/B by ear:** bake the same sentence with the compact voice and with the
      Premium voice to two opaquely-named files, play them in random order five times, and
      write down which is which. Passes at five of five correct **and** the Premium voice
      preferred. Still by ear, now recorded and able to fail.
- [ ] The spoken word highlights in step with the audio. *(PARTIAL: callbacks fire and the
      UTF-16 conversion is unit-tested against accents and an emoji. Watching it track the
      audio needs eyes on the screen.)*
- [x] The catalog reports that no good voice is installed, so the banner is warranted, and
      banner precedence is unit-tested: dismissing an advisory cannot hide a permission
      problem. *(Opening the settings pane needs a click.)*
- [x] Baking a sentence writes a playable file into the passage folder.
- [x] Switching voices takes effect on the next playback and survives a relaunch: the
      choice is stored by identifier in user defaults and resolved through
      `VoiceRanking.resolve`, which is tested for both the honored and the fallback case.
- [x] `AppleVoiceProvider.dataLeavesDevice` is false.


## Findings while executing this item

**The ranking picked a novelty voice, and only running it revealed that.** Every
preinstalled voice is the same quality tier, so ranking by tier and then by name fell
through to alphabetical order and selected **Albert** — one of the old MacinTalk toys,
alongside Bad News, Bubbles, Trinoids and Zarvox. Technically speech. Useless as a
pronunciation reference, and precisely the class of silent wrongness this item exists to
prevent.

The fix is a voice *family* inferred from the identifier: downloadable, then system, then
Eloquence, then novelty. Ranking is now tier, family, American English, name. With that,
selection returns Samantha from the realistic preinstalled set, which is asserted by test.

**Word callbacks are not one per word.** Albert emitted 9 ranges for an 8-word sentence,
apparently giving the trailing period its own range; Samantha emitted 8. So the count
varies by voice, and the app must consume ranges as they arrive rather than assuming a 1:1
mapping. The existing rule — a voice emitting no ranges degrades to highlighting the whole
sentence — is right, and this widens it: do not count on the arithmetic either.

**A probe that pumps the run loop cannot be `async`.** `RunLoop.current` and
`run(mode:before:)` are both unavailable from an async context, so `VoiceProbe` uses a
synchronous entry point. `BakeProbe` can be async, because its continuation is driven by the
concurrency runtime rather than by a run loop it has to pump itself. Any later probe has to
pick the right one of these two shapes.

**A layering violation surfaced immediately.** `PracticeController` initially took a
`Settings` object, which lives in the app layer — a service reaching upward. The probe build
compiles Core and Services only, so it failed instantly. The controller now takes the voice
and rate per call, and the dependency points one way.

## Measured

| Thing | Value |
| --- | --- |
| Installed English voices | 42: Ava (Premium) plus 41 at the lowest tier |
| Synthesis output | 22050 Hz, 1 channel, non-interleaved |
| Frames for one sentence | 65,935 |
| Baked file | 194 KB, 47,550 frames, 2.16 s, accepted by `AVAudioPlayer` |
| Bake time | 0.28 s |

Recordings are 44100 Hz, so anything feeding both into one buffer pipeline must convert.
Item 10 does that. Ava also synthesizes at 22050 Hz through the write path, so installing a
premium voice does not change that mismatch.

## The installed identifier is not the advertised one

The asset catalog lists Ava as `com.apple.ttsbundle.Ava`. The **installed** voice reports
`com.apple.voice.premium.en-US.Ava`, and its display name is "Ava (Premium)" rather than
"Ava".

That matters because the family inference added earlier keyed on `com.apple.ttsbundle` for
downloadable voices. It still selected Ava correctly, because tier outranks family and Ava
reports as premium — but the family classification was wrong, and a rule built only from
the catalog would have been wrong in a way nothing would have surfaced. Both prefixes are
now recognized, and the observed identifiers are pinned by test so a refactor cannot
quietly reclassify a real installed voice.

This is also why the app matches voices by identifier rather than by display name: the name
carries a localized "(Premium)" suffix.
