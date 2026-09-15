#!/bin/bash
# Compiles and runs the test suite. This is the loop to live in: no frameworks beyond
# Foundation and NaturalLanguage, no permission prompts, about a second end to end.
#
# Uses swift-testing, which ships with Command Line Tools. Xcode is NOT required.
# `swift test` does not work here because SwiftPM looks for Xcode's Platforms directory
# and so never wires up the framework search path -- that is a SwiftPM integration gap,
# not an absent library. Driving swiftc directly with the four flags below works, which
# was verified before this script was written.
#
# Pass a filter to run a subset:   ./test.sh --filter Scorer
set -euo pipefail
cd "$(dirname "$0")"

CLT="$(xcode-select -p)"
FRAMEWORKS="$CLT/Library/Developer/Frameworks"
PLUGINS="$CLT/usr/lib/swift/host/plugins/testing"
INTEROP="$CLT/Library/Developer/usr/lib"
TARGET="arm64-apple-macos14.0"
SDK="${ORAL_SDK:-$(xcrun --show-sdk-path)}"
OUT="build/runtests"

# These are unversioned toolchain internals. If a Command Line Tools update moves them,
# fail here with a clear message rather than deep inside a link error.
for p in "$FRAMEWORKS/Testing.framework" "$PLUGINS/libTestingMacros.dylib" "$INTEROP/lib_TestingInterop.dylib"; do
    if [ ! -e "$p" ]; then
        echo "swift-testing component missing: $p" >&2
        echo "A Command Line Tools update may have moved it. Re-check with:" >&2
        echo "  find \"$CLT\" -name 'Testing.framework' -o -name 'lib_TestingInterop.dylib'" >&2
        exit 1
    fi
done

# The rule the whole test loop depends on.
./scripts/check-core-imports.sh

SRC=()
while IFS= read -r -d '' f; do
    SRC+=("$f")
done < <(find Sources/Core Tests -name '*.swift' -print0 2>/dev/null)

if [ ${#SRC[@]} -eq 0 ]; then
    echo "No sources found under Sources/Core or Tests." >&2
    exit 1
fi

mkdir -p build
swiftc -parse-as-library -Onone \
    -target "$TARGET" -sdk "$SDK" \
    -swift-version 6 \
    -F "$FRAMEWORKS" -framework Testing \
    -plugin-path "$PLUGINS" \
    -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$INTEROP" \
    -o "$OUT" \
    "${SRC[@]}" Sources/Tools/TestMain.swift

# Never pipe the runner: a pipeline's exit status is the last command's, so piping into
# tee or grep would silently turn a failing suite into a passing build.
"$OUT" "$@"
