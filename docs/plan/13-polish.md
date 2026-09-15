# 13 — Polish

**Verification style:** checklist, and the test for this item is subtractive.

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

- [ ] A fresh passage with no takes shows no score numbers, no rings, and no footer.
- [ ] The control count is at or below the committed baseline.
- [ ] None of the seven rejected elements is present, asserted not eyeballed.
- [ ] The full practice loop runs from the keyboard without the mouse.
- [ ] An empty library opens into the paste box.
- [ ] Every error message says what happened and what to do, with no raw error text, **and**
      the full error appears in the log.
- [ ] Copy diagnostics produces something a developer could act on.
- [ ] Dark mode is legible throughout, with no hardcoded colors.
- [ ] Window resizing keeps the layout sensible, including a narrow window.
- [ ] Scrolling a 30-sentence passage meets the frame budget while a take is scoring.
- [ ] A take whose audio is missing presents greyed with its score still readable.
- [ ] `./test.sh` passes.
- [ ] The user looks at it and does not say it is too complicated.

## Deferred, deliberately

An app icon, baked reference audio for every sentence, overlay A/B by default, and a
passage-level "words to work on" view. That last one is a frequency count over the problem
words already stored on every take, so it is cheap if wanted later.
