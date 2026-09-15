# 07 — The reference voice

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

- [ ] A Premium voice is installed and its actual identifier and tier are recorded in the
      overview.
- [ ] The probe reports non-zero frames and one callback per word.
- [ ] `./test.sh` passes, including the ranking and range-conversion tests.
- [ ] **Blind A/B by ear:** bake the same sentence with the compact voice and with the
      Premium voice to two opaquely-named files, play them in random order five times, and
      write down which is which. Passes at five of five correct **and** the Premium voice
      preferred. Still by ear, now recorded and able to fail.
- [ ] The spoken word highlights in step with the audio.
- [ ] Forcing the catalog to report no good voice shows the banner, and its button opens the
      right settings pane. Dismissing it does not hide a permission banner.
- [ ] Baking a sentence writes a playable file into the passage folder.
- [ ] Switching voices mid-session takes effect on the next playback, and survives a relaunch.
- [ ] `AppleVoiceProvider.dataLeavesDevice` is false.
