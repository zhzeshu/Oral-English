# 13 — Polish

**Status:** PARTIAL — 2026-09-14. The structural restraint is built and machine-checked;
the visual and perceptual gates are BLOCKED, because screen recording and assistive access
are both denied to this session.
**Changed:** Sources/Views/TransportBarView.swift (new), Sources/Views/*.swift throughout,
Sources/App/AppModel.swift
**Verified:** ./test.sh (242 tests in 18 suites), ./build.sh clean, and the subtractive grep
below

**Verification style:** checklist, and the test for this item is subtractive.

**2026-10-19 — three things reported from real use.**

**The page was black.** The app followed the system appearance, which on this Mac is dark,
so the surface you read aloud from was near-black. `Styling` now carries a small light
palette and `RootView` pins `.preferredColorScheme(.light)`. Pinned rather than offered as
a preference: this is a reading surface and should look like paper under every system
setting. Two colors do the work — teal for anything pressable, amber for the word being
spoken and nothing else. Keeping them apart matters; one accent for both would make the
spoken word look like another button. The score bands were re-darkened, because `.green`
and `.mint` are tuned for dark backgrounds and wash out to pastel on cream.

**You could not hear yourself.** Playing your own take required opening the take history,
while this menu had advertised "⌘P — play my take" since the screen was built. `playBestTake`
plus a `person.wave.2.fill` button on the row — deliberately not a second play triangle,
because two identical glyphs side by side is how you press the wrong one. Best take rather
than most recent, so the audio and the percentage on the row refer to the same take. The
whole advertised shortcut list is now real: ⌘L reference, ⌘R record, ⌘P your take, ⌘B
compare, ⌘↓ next. Space was the natural key for playback and is deliberately avoided — it
would swallow spaces in the paste sheet.

**Ava still sounded mechanical.** Two causes in our own code, one ceiling that is not ours:

- The rate was 0.45 against a default of 0.5. A premium voice's prosody is tuned at its own
  rate, and slowing it stretches vowels and flattens intonation — heard as mechanical rather
  than as slow. This was the single biggest change.
- Sentences ran back to back with no gap. `postUtteranceDelay = 0.18` gives a breath at a
  full stop, which is most of what makes paragraph reading sound read rather than recited.
- The ceiling: premium is the best tier `AVSpeechSynthesizer` exposes, and Siri voices are
  not available to third-party apps. This machine has **1 premium voice installed out of
  42**; the other 41 are the compact tier. More premium voices is choice, not a higher tier.
  "Get More Voices…" now sits in the Voice menu, and a Speed submenu exposes the rate.

**2026-10-19 — the app did not open and close like a Mac app.**

A SwiftUI `WindowGroup` keeps the process alive after its last window closes. That is right
for a document app -- Pages with no document open is still Pages -- and wrong for this one,
which has exactly one window and one library. Closing the window left a running process with
no window and a Dock icon that looked like a dead app.

`AppLifecycle`, an `NSApplicationDelegate`, restores what every other single-window Mac app
does: `applicationShouldTerminateAfterLastWindowClosed` returns true, and
`applicationShouldHandleReopen` brings a window back if one is somehow running without one.

It also gave `AppModel.shutdown` its first caller. That method releases the single-instance
lock and had **no caller at all**, so the one thing it exists to guard was guarded only by
the file descriptor dying with the process.

Not a bug, but worth recording because it looks like one: the window restores to wherever it
last was, and on a two-display Mac that can be the display you are not looking at. The app
opens and appears to do nothing.

## Goal

Make the app feel finished and calm. The user reviewed three mockups, chose the native Mac
direction, then explicitly asked for it to be simpler. That instruction governs this item.

## The rule for this item

**Anything on screen that is not needed at that moment comes off.** When in doubt, remove it.
"Too cluttered" was the actual feedback, so the bias is not neutral.

Already rejected and must not creep back: a permanent row of status chips, score rings drawn
as filled blobs, borders between sentence rows, paragraph label dividers, an always-visible
take history table, a permanent voice banner, and keyboard shortcuts printed in the footer.

## Files

`Sources/Views/` throughout, plus `Styling.swift`.

## What to do

**Restraint.** The passage reads as a single column with no borders and no paragraph labels,
separated by whitespace alone, at comfortable reading size and generous line height. The only
thing at the right margin is accuracy as a small muted number, blank until the sentence has
been attempted, so a fresh passage shows no scoring furniture at all.

**Contextual controls.** The three icon buttons appear only on the row being worked on, which
also takes a faint background fill.

**Collapsed detail.** Under the active row, one plain-language line naming what was heard and
one muted line with the percentage and take count. Take history opens from that take count
rather than sitting on screen.

**Transient chrome.** The bottom status line exists only while audio is active. When nothing
is happening there is nothing there.

**Menu, not chrome.** Voice, rate, export, transcripts-only export, reveal in Finder, rename,
keyboard shortcuts, copy diagnostics, and the voice-download prompt all live behind the
ellipsis menu.

**Keyboard loop.** Space plays the reference, Command-R records, Command-P plays the take,
Command-B does A/B, Command-Down moves on. Listed in the menu, not printed on screen.

**Empty states.** An empty library opens straight into the paste box. An invitation, not an
apology: name the space and give a verb.

**Error copy.** Say what happened, then what to do, in one sentence. No first person, no
exclamation marks, and **no raw error strings in the UI** — but every error is logged in full,
per item 02. Revision 1 forbade raw error text without adding a log, so a silent failure left
no trace anywhere. "Copy diagnostics" in the menu dumps recent log entries plus the selected
voice and tier, both permission states, whether the offline model is available, the library
path, and free disk space.

**Rename, not edit.** Rename is supported and renames the folder, only when no audio activity
is in flight. Editing a passage's text after the first take is out of scope; offer
duplicate-with-edited-text instead, because re-splitting changes sentence identity and would
orphan every existing take.

**Missing recordings** present as a greyed take with one muted line, score still readable.

**Observation granularity.** Rows read only their own `RowSummary` from item 04. Never call
the tokenizer, the aligner, or a take scan from a view body.

## Falsifiable underneath the subjective gate

The user's verdict stays as the final sign-off — a proxy metric would be worse. But add a layer
that can fail on its own, because "the user does not say it is too complicated" cannot catch
chrome creeping back over months:

- For a fresh passage with no takes, assert the count of visible interactive controls is at or
  below a committed baseline.
- Turn the seven rejected elements above into assertions over an accessibility-tree dump.
- Quantify smoothness as a frame-time budget rather than the word "smooth".

The count catches regression; the verdict catches design. Revision 1 had only the second.

## Done when

- [x] A fresh passage with no takes shows no score numbers, no rings, and no footer. The
      accuracy slot renders `Color.clear` until a target has been attempted, and the
      transport bar returns nothing at all when audio is idle.
- [ ] *(BLOCKED: needs a human at the screen)* The control count is at or below the committed baseline.
- [x] None of the seven rejected elements is present. Checked by grep: no score rings, no
      dividers between sentence rows (the three that exist are menu separators and one above
      the sidebar button), no paragraph label dividers, no always-visible take history table,
      no shortcuts printed in the footer, and no status chip row — the only match for "chip"
      is a comment recording that they were removed.
- [ ] *(BLOCKED: needs a human at the screen)* The full practice loop runs from the keyboard without the mouse.
- [ ] *(BLOCKED: needs a human at the screen)* An empty library opens into the paste box.
- [x] Every error message says what happened and what to do, with no raw error text, and
      the full error goes to the log. This is machine-checked: `AppFailureTests` asserts
      across all sixteen cases that no message leaks `NSError`, `Error Domain` or `OSStatus`,
      none speaks in the first person, none shouts, each names an action, and each fits in
      140 characters.
- [ ] Copy diagnostics produces something a developer could act on. *(The log layer and the
      `log show` predicate exist; the menu item is not wired.)*
- [x] No hardcoded colors: zero hits for raw hex, `Color(red:)` or calibrated `NSColor`
      across the view layer. Everything uses semantic styles. *(Judging legibility still
      needs eyes.)*
- [ ] *(BLOCKED: needs a human at the screen)* Window resizing keeps the layout sensible, including a narrow window.
- [ ] *(BLOCKED: needs a human at the screen)* Scrolling a 30-sentence passage meets the frame budget while a take is scoring.
- [ ] *(BLOCKED: needs a human at the screen)* A take whose audio is missing presents greyed with its score still readable.
- [x] `./test.sh` passes.
- [ ] *(BLOCKED: needs a human at the screen)* The user looks at it and does not say it is too complicated.

## Deferred, deliberately

An app icon, baked reference audio for every sentence, overlay A/B by default, and a
passage-level "words to work on" view. That last one is a frequency count over the problem
words already stored on every take, so it is cheap if wanted later.


## What is genuinely done

The restraint is structural rather than cosmetic, which is why most of it could be checked
without looking at the screen:

- The accuracy slot is `Color.clear` until a target has been attempted, so a fresh passage
  carries no scoring furniture at all.
- The transport bar is inside an `if let label = activity.label`, so it renders nothing when
  audio is idle rather than rendering an empty bar.
- Controls appear only on the active row; other rows show a muted number or nothing.
- Voice, rate, rename, reveal, export and the keyboard list all live behind the ellipsis
  menu, so nothing that used to be a chip row is on screen.
- Row inputs are small equatable values from `AppModel.rowSummaries`, recomputed once per
  mutation, so no view body scans the take array.

## What is not

The control-count baseline, the frame budget, the accessibility-tree assertions and the
keyboard loop all need either a human or an automation permission this session does not
have. They are listed as blocked rather than assumed, which is the same standard item 04
applied to its UI gates.
