#!/bin/bash
# Compiles and runs one probe from Sources/Tools.
#
#   ./probe.sh VoiceProbe [args...]
#
# Probes exist because items 07 through 10 drive AVFoundation and Speech, which need a run
# loop, real hardware, or a privacy grant. A probe proves the framework behaves as expected
# before any app code depends on it. Each gets Core plus the frameworks it needs.
set -euo pipefail
cd "$(dirname "$0")"

NAME="${1:-}"
if [ -z "$NAME" ]; then
    echo "Usage: ./probe.sh <ProbeName> [args...]" >&2
    echo "Available:" >&2
    ls Sources/Tools/*Probe.swift 2>/dev/null | xargs -n1 basename 2>/dev/null | sed 's/\.swift$/  /' >&2 || echo "  (none yet)" >&2
    exit 1
fi
shift

SRC="Sources/Tools/$NAME.swift"
[ -f "$SRC" ] || { echo "No such probe: $SRC" >&2; exit 1; }
# ProbeApp is shared support, not a probe. TestMain must never be compiled in: it carries
# its own @main and would collide.
[ "$NAME" = "ProbeApp" ] && { echo "ProbeApp is shared support, not a probe." >&2; exit 1; }

# Core plus Services. Not App or Views: those carry the app's own @main and its SwiftUI
# scene, which would collide with the probe's entry point.
CORE=()
while IFS= read -r -d '' f; do CORE+=("$f"); done < <(find Sources/Core Sources/Services -name '*.swift' -print0)

mkdir -p build
plutil -lint Resources/ProbeInfo.plist >/dev/null

# Probes are built INTO a real .app bundle, not as a bare binary.
#
# Both are needed, for different reasons, and this took a crash to work out:
#   - The embedded __info_plist section satisfies TCC's own daemon, which is what makes the
#     microphone grant possible.
#   - The Speech framework instead reads NSBundle.mainBundle, which a bare command-line
#     binary does not have. Without a bundle on disk it crashes with
#     "must contain an NSSpeechRecognitionUsageDescription key" even though the section is
#     present and correct.
#
# Running Contents/MacOS/<name> directly, rather than via `open`, keeps stdout on the
# terminal while still letting mainBundle resolve to the bundle.
# Built as a real .app under build/.
#
# Location is NOT what governs the privacy prompt — tried from ~/Applications too, with the
# same result. What governs it is whether the launching session can present a dialog at all.
APP="build/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Resources/ProbeInfo.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $NAME" "$APP/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $NAME" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$APP/Contents/Info.plist" 2>/dev/null || true

# -parse-as-library, so each probe uses an explicit @main entry point. Top-level code is
# only allowed in a file called main.swift, and a probe needs its own name.
#
# The embedded __info_plist section is what makes a microphone or speech probe possible at
# all. macOS privacy refuses a process with no usage string and **kills it** rather than
# prompting -- a bare CLI binary asking for the microphone aborts with no explanation. Since
# the plist has to be embedded in the binary rather than sitting beside it, this is the
# supported way to give a command-line tool one. The probe is then ad-hoc signed so it has
# a code identity for the grant to attach to.
swiftc -Onone -parse-as-library \
    -target arm64-apple-macos26.0 -sdk "$(xcrun --show-sdk-path)" \
    -swift-version 6 \
    -framework AVFoundation -framework Speech -framework AppKit \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist \
    -Xlinker Resources/ProbeInfo.plist \
    -o "$APP/Contents/MacOS/$NAME" \
    "${CORE[@]}" Sources/Tools/ProbeApp.swift "$SRC"

# Compile-only escape hatch. Probes are excluded from both build.sh and test.sh -- they
# each carry their own @main -- so nothing else notices when one stops compiling after a
# change to Core or Services. This makes "does every probe still build?" a one-liner:
#
#   for p in Sources/Tools/*Probe.swift; do
#       ORAL_PROBE_BUILD_ONLY=1 ./probe.sh "$(basename "$p" .swift)"
#   done
if [ "${ORAL_PROBE_BUILD_ONLY:-0}" = "1" ]; then
    echo "compiled $NAME"
    exit 0
fi

# Sign the bundle so there is a code identity for any privacy grant to attach to. Prefer
# the project certificate when it exists, so probe grants are as stable as the app's.
SIGN="${ORAL_PROBE_SIGN_ID:-}"
if [ -z "$SIGN" ] && [ -f .signing-identity ]; then SIGN="$(cat .signing-identity)"; fi
codesign --force --sign "${SIGN:--}" --options runtime "$APP" >/dev/null 2>&1 \
  || codesign --force --sign - "$APP" >/dev/null 2>&1 || true

# Launch with `open`, not by running the binary.
#
# This is the same trap the app documents, and it bites probes harder. Running
# Contents/MacOS/<name> from a terminal makes the TERMINAL the responsible process for
# privacy, so TCC checks the terminal's Info.plist for the usage string, finds none, and
# **kills the process** — with a message claiming the key is missing even though
# NSBundle.mainBundle reads it back correctly. Verified both ways.
#
# `open -W` waits for exit and `--stdout/--stderr` bring the output back, so the probe
# keeps its own privacy identity and still prints to the terminal.
LOG="build/$NAME.log"
: > "$LOG"
if [ "${ORAL_PROBE_DIRECT:-0}" = "1" ]; then
    # Escape hatch: run in-process, for probes that need no privacy-gated API and where a
    # live progress bar is more useful than captured output.
    "$APP/Contents/MacOS/$NAME" "$@"
else
    open -W --stdout "$LOG" --stderr "$LOG" -a "$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")" --args "$@"
    cat "$LOG"
fi
