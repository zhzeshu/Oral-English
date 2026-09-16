# 01 — Bundle, signing, and a window

**Status:** DONE — 2026-09-14 (one gate BLOCKED on the user, see below)
**Changed:** build.sh, make-cert.sh, run.sh, test.sh, scripts/check-core-imports.sh,
.gitignore, .git/hooks/pre-commit, Resources/Info.plist,
Sources/App/OralEnglishApp.swift, Sources/Views/RootView.swift,
Sources/Tools/TestMain.swift, Tests/HarnessTests.swift
**Verified:** ./build.sh (signature verified, Authority=Oral English Dev),
./test.sh (6 tests in 1 suite passed), app launched from ~/Applications
**Blocked gate:** the microphone-grant-survives-rebuild check needs a record button
(item 08) and the user to click Allow. Identity stability was verified instead.

**Verification style:** checklist. There is no logic here to unit-test; the risk is
entirely in bundle mechanics and code identity.

> Revision 2. `build.sh`, `run.sh`, `test.sh`, `make-cert.sh` and
> `scripts/check-core-imports.sh` are already written and verified working. What remains in
> this item is the certificate, the git hook, and the end-to-end grant check.

## Goal

A double-clickable `Oral English.app` that launches and shows an empty window, signed with
a stable identity so that privacy grants earned later survive every rebuild.

## Why this is first

Bundle mechanics on an empty app take minutes to get right. The same mechanics debugged
underneath a half-written app take an afternoon, because every symptom looks like an
application bug. The certificate in particular must exist before any code touches the
microphone, or the first grant is attached to a throwaway identity.

## Files

- `make-cert.sh`, `build.sh`, `run.sh`, `test.sh`, `scripts/check-core-imports.sh` — done
- `Resources/Info.plist` — done
- `Sources/App/OralEnglishApp.swift` — to write
- `.git/hooks/pre-commit` — to write

## The certificate

macOS ties a privacy grant to code identity. An ad-hoc signature has no certificate chain,
so the grant keys on the binary hash and breaks on every rebuild. The symptom is usually a
re-prompt, but is sometimes a silent denial where the microphone returns nothing and no
dialog appears. Over thirteen work items that would bite dozens of times.

`make-cert.sh` mints a self-signed certificate with the code-signing extended key usage and
imports it into the login keychain. Run once. Three details matter and are already handled:

- It preflights for `openssl pkcs12 -legacy` and fails with instructions. The system
  openssl is LibreSSL and rejects that flag, while macOS `security import` requires it.
  Revision 1 discarded stderr here and so exited silently on a stock Mac.
- The key is imported with `-T /usr/bin/codesign` and `-x`, never `-A`. `-A` would let any
  process running as this user sign code with the certificate, forge this app's identity,
  and inherit its microphone grant with no prompt.
- The certificate is never added to a trust store.

Expect one keychain prompt the first time `codesign` uses the key. Choose Always Allow.

Fallbacks, in order: the Keychain Access certificate assistant, then ad-hoc signing
(`ORAL_SIGN_ID=- ./build.sh`) plus `tccutil reset` when a grant wedges. `build.sh` warns
loudly in ad-hoc mode, because that mode silently gives up the property this item exists to
establish.

## Rules that are easy to get wrong

- **Build to the same path every time.** `~/Applications/Oral English.app`. Privacy
  bookkeeping uses the path as well as the identifier.
- **Never change the bundle identifier.** `com.zackzhang.oralenglish`.
- **Launch with `open`, never the binary directly.** Running the executable from a terminal
  gives the process the terminal's privacy identity, so grants do not carry over to Finder
  launches. `run.sh` does this correctly.
- **Do not use `--deep`.** There are no nested bundles; it is deprecated.
- The executable name inside `Contents/MacOS/` must exactly equal `CFBundleExecutable`.
- **`--options runtime` is set.** Without the hardened runtime,
  `DYLD_INSERT_LIBRARIES` works, so any same-user process can inject a dylib and use the
  microphone under this app's grant. It works with a self-signed certificate; only
  notarization would need a Developer ID, which this app does not seek.
- **Never let `codesign` failures pass.** Revision 1 piped both the sign and verify steps
  through `grep` and appended `|| true`, which discarded the exit status, so a failed
  signature installed over a working app and presented later as a dead microphone. Status is
  now captured separately from display, and the install is gated on verification.

## Info.plist keys

Beyond the ordinary bundle keys, three usage strings are required:

- `NSMicrophoneUsageDescription`
- `NSSpeechRecognitionUsageDescription`
- `NSDocumentsFolderUsageDescription`

The third is the one people forget. A non-sandboxed app writing to Documents on modern
macOS is **terminated rather than prompted** when that string is missing, which presents as
a mysterious crash in work item 04.

No entitlements file and no App Sandbox. That decision was re-examined during review and
kept, but for corrected reasons: sandboxing genuinely would contain blast radius, and a zip
can be produced under the sandbox with `NSFileCoordinator`'s uploading intent, so the real
cost is the first-run folder pick, the security-scoped bookmark, and losing a predictable
library path. That is the trade being made. The hardened runtime covers the injection risk
that mattered most.

## The git hook

There is no continuous integration, so a pre-commit hook running `./test.sh` is the whole
regression story. Five minutes, and it defaults to running rather than to being remembered.
Revision 1 asked only two of twelve items to keep the suite green, as hand-ticked boxes.

## Done when

- [x] `git init` done and a pre-commit hook runs `./test.sh` and blocks the commit on failure.
- [x] `./make-cert.sh` completes and `security find-identity -v -p codesigning` lists the
      certificate exactly once.
- [x] `./build.sh` completes and prints `signature verified`.
- [x] Deliberately corrupting the staged binary makes `build.sh` **exit non-zero** and leave
      `~/Applications/Oral English.app` untouched.
- [x] `codesign -dv` on the installed app reports an `Authority=` line, not `adhoc`.
- [x] `./run.sh` opens a window, and the name in the menu bar and Dock reads "Oral English".
- [x] `./test.sh` passes.
- [ ] **The grant survives a rebuild.** *(BLOCKED on the user — needs item 08's record
      button and a click on Allow. The mechanism was partly verified: `Authority=Oral
      English Dev` is identical across rebuilds.)* Run the app, grant the microphone at a temporary
      test button, rebuild, relaunch, and confirm it does not prompt again. Record the
      result in this file. Every later item assumes this works and nothing has shown it does.
- [x] `tccutil reset Microphone com.zackzhang.oralenglish` was run once and its output
      recorded. OSStatus −10814 means TCC holds no record, which is benign.

## Notes

Whole-module compilation of around twenty files takes a couple of seconds, so do not build
incremental-compilation machinery. `build.sh` exposes the signing identity, optimization
level, Swift language version, and SDK path as environment variables with sane defaults,
purely as an escape hatch. Default to `-swift-version 6`; retrofitting strict concurrency is
worse than paying for it now.


## Findings while executing this item

Four things the plan did not predict, all now fixed in the scripts:

1. **An empty PKCS#12 password cannot be imported.** `security import` fails with "MAC
   verification failed during PKCS12 import", regardless of `-macalg`, because OpenSSL and
   the Security framework disagree on the MAC over an empty passphrase. Verified against a
   throwaway keychain. `make-cert.sh` now generates a fresh random password per run. The
   trade-off is that `security import -P` takes it on the command line, where `ps` can see
   it for the duration; the password is never reused or stored, and that tool has no stdin
   alternative.
2. **`find-identity -v` hides a self-signed certificate.** It reports
   `CSSMERR_TP_NOT_TRUSTED` and is filtered out by `-v`, so both scripts reported "0 valid
   identities found" and refused to work — while `codesign` uses the identity perfectly
   well. Both checks dropped `-v`.
3. **The `Authority=` line needs `-dvv`, not `-dv`.** At single verbosity codesign prints
   only `Signature size=`, so the non-ad-hoc assertion silently never matched.
4. **`grep -q` under `set -o pipefail` inverted the assertion.** grep exits on first match,
   codesign takes SIGPIPE, and the pipeline reports failure on the *success* path — so a
   correctly signed bundle was rejected. Output is now captured before matching. This is the
   same class of bug as the `|| true` defect the review found: shell status handling around
   codesign is where this project keeps tripping.

Also: `tccutil reset Microphone com.zackzhang.oralenglish` now succeeds, where it returned
OSStatus −10814 before the app was ever signed and launched. The −10814 note in `build.sh`
is still correct for the pre-first-launch state.

## The app icon — 2026-09-15

`Resources/AppIcon.icns`, generated by `./make-icon.sh` from
`Sources/Icon/MakeIcon.swift`. Drawn in CoreGraphics rather than stored as a binary blob,
so it is reviewable in a diff and re-renderable at whatever sizes a future macOS wants. The
renderer links nothing from `Sources/` — CoreGraphics and ImageIO only — so it cannot drag
`Speech` into a build that does not need it.

**The mark:** a reference waveform in two bursts above a row of six word marks, the fourth
hollow. That is the product in two elements — hear a sentence read properly, then see which
words were understood. A microphone would have illustrated the least interesting thing the
app does.

**Detail is a function of size, not one master downsampled.** A 1024 render scaled to 16px
turns six dots into grey mush, so the renderer draws three tiers: the full mark at 128 and
above, eight bars and four dots at 32–64, and at 16 just a waveform over a single soft bar,
which is the silhouette that still reads. The hollow ring's weight also varies by tier,
because a ring thin enough to show a clear hole at 512 disappears entirely at 32.

**Two things that had to be fixed for the icon to appear at all.** `build.sh` already copied
`Resources/AppIcon.icns` when present, but `Info.plist` had no `CFBundleIconFile`, so macOS
would have ignored the file. And `iconutil -c icns` can exit 0 having silently dropped
sizes, so `make-icon.sh` converts the result *back* to an iconset and counts the PNGs rather
than trusting the exit status.

**Rejected:** a superellipse plate. Continuous curvature should in theory sit better beside
system icons, but at this corner ratio the shape is mostly corner, so the flattening
dominated the silhouette and it rendered as an organic petal-like blob. A plain rounded rect
at Apple's 0.225 ratio is both closer to the system shape and predictable across sizes.

**Also fixed here:** `LSMinimumSystemVersion` was still `14.0` after item 10 raised the
compile target to macOS 26.0. The app therefore advertised that it ran on macOS 14, where
`SpeechTranscriber` does not exist — a launch-then-crash. It is now `26.0`. Anything that
changes the target must change both.
