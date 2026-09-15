# Oral English

A macOS app for practicing spoken English. Paste a paragraph, hear each sentence read by a
native-sounding reference voice, record yourself reading it, and see which words were
actually understood.

Everything stays on this machine, in a browsable folder under Documents.

## Requirements

macOS 14 or later on Apple Silicon. Command Line Tools are enough; Xcode is not needed.

## Getting started

```bash
./make-cert.sh
```

Run once. It creates a local code-signing certificate so that microphone permission
survives rebuilds.

```bash
./run.sh
```

Builds the app, installs it to `~/Applications`, and opens it.

```bash
./test.sh
```

Runs the test suite with swift-testing, which ships with Command Line Tools. Fast, needs no
permissions, and is the loop to work in.

## A note on voice quality

Every English voice that ships preinstalled is the lowest quality tier, which is why
built-in speech sounds robotic. Install a Premium voice for natural American English:

System Settings, then Accessibility, then Spoken Content, then System Voice, then Manage
Voices. Tick Ava, or Tom for a male voice.

The app detects this and prompts on first run.

## Plan

The implementation plan lives in [docs/plan/](docs/plan/), split into thirteen work items
in execution order. Start with [the overview](docs/plan/00-overview.md), which covers the
decisions behind the design, the verified facts about this machine, and how testing works.

The plan is at revision 2, rewritten after an adversarial review recorded in
[grill-report-2026-09-14.md](grill-report-2026-09-14.md).
