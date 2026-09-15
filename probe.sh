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

# Core plus Services. Not App or Views: those carry the app's own @main and its SwiftUI
# scene, which would collide with the probe's entry point.
CORE=()
while IFS= read -r -d '' f; do CORE+=("$f"); done < <(find Sources/Core Sources/Services -name '*.swift' -print0)

mkdir -p build
# -parse-as-library, so each probe uses an explicit @main entry point. Top-level code is
# only allowed in a file called main.swift, and a probe needs its own name.
swiftc -Onone -parse-as-library \
    -target arm64-apple-macos14.0 -sdk "$(xcrun --show-sdk-path)" \
    -swift-version 6 \
    -framework AVFoundation -framework Speech -framework AppKit \
    -o "build/$NAME" \
    "${CORE[@]}" "$SRC"

"build/$NAME" "$@"
