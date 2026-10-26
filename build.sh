#!/bin/bash
# Builds Oral English.app and installs it to ~/Applications.
#
# Always builds to the same path with the same bundle identifier, because macOS privacy
# bookkeeping uses both. Changing either will make the microphone prompt reappear.
#
# Environment overrides, all optional:
#   ORAL_SIGN_ID        signing identity (default: the local dev certificate, "-" for ad-hoc)
#   ORAL_SWIFT_VERSION  5 or 6 (default 6; escape hatch if strict concurrency blocks you)
#   ORAL_OPT            -Onone or -O (default -Onone)
#   ORAL_SDK            override the SDK path (default: xcrun --show-sdk-path)
#
# If a privacy grant ever wedges into silent denial:
#   tccutil reset Microphone com.zackzhang.oralenglish
#   tccutil reset SpeechRecognition com.zackzhang.oralenglish
# "No such bundle identifier" (OSStatus -10814) means TCC holds no record for the app.
# That is benign, not a failure. If the microphone is still dead, remove the app from
# System Settings > Privacy & Security > Microphone and relaunch.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Oral English"
EXEC_NAME="OralEnglish"
BUNDLE_ID="com.zackzhang.oralenglish"
DEPLOY="$HOME/Applications/$APP_NAME.app"
STAGE="build/$APP_NAME.app"
TARGET="arm64-apple-macos26.0"
SDK="${ORAL_SDK:-$(xcrun --show-sdk-path)}"
# Command Line Tools 27 made the macOS 27 SDK the default. There, SwiftUI's @State is a
# macro, and the SwiftUIMacros compiler plugin that expands it ships with Xcode, not with
# Command Line Tools -- so every @State fails with "plugin for module 'SwiftUIMacros' not
# found". The same install keeps the 26 SDK, which is what this app targets anyway.
if [ -z "${ORAL_SDK:-}" ]; then
    PLUGINS="$(dirname "$(xcrun -f swiftc)")/../lib/swift/host/plugins"
    SDK26="$(dirname "$SDK")/MacOSX26.sdk"
    if ! ls "$PLUGINS"/libSwiftUIMacros* >/dev/null 2>&1 && [ -d "$SDK26" ]; then
        SDK="$SDK26"
    fi
fi
# Prefer the hash recorded by make-cert.sh: signing by hash cannot be ambiguous.
if [ -z "${ORAL_SIGN_ID:-}" ] && [ -f .signing-identity ]; then
    SIGN_ID="$(cat .signing-identity)"
else
    SIGN_ID="${ORAL_SIGN_ID:-Oral English Dev}"
fi
SWIFT_VERSION="${ORAL_SWIFT_VERSION:-6}"
OPT="${ORAL_OPT:--Onone}"

# --- Identity check -----------------------------------------------------------------
# Match fixed strings, not regexes, and require exactly one hit. A substring or regex
# match can silently select a different identity; two identities with the same common
# name make `codesign --sign` fail as ambiguous.
if [ "$SIGN_ID" = "-" ]; then
    echo "WARNING: building ad-hoc. Code identity changes on every rebuild, so the"
    echo "         microphone and speech-recognition grants will NOT survive. Run"
    echo "         ./make-cert.sh for a stable identity."
else
    # No -v: a self-signed certificate is reported CSSMERR_TP_NOT_TRUSTED and would be
    # filtered out, even though codesign uses it happily.
    matches=$(security find-identity -p codesigning | grep -c -F "$SIGN_ID" || true)
    if [ "$matches" -eq 0 ]; then
        echo "Signing identity \"$SIGN_ID\" not found. Run ./make-cert.sh first," >&2
        echo "or build ad-hoc with: ORAL_SIGN_ID=- ./build.sh" >&2
        exit 1
    elif [ "$matches" -gt 1 ]; then
        echo "Expected exactly one identity matching \"$SIGN_ID\", found $matches." >&2
        echo "codesign would fail as ambiguous. Remove the duplicate with:" >&2
        echo "  security delete-identity -Z \"$SIGN_ID\"" >&2
        exit 1
    fi
fi

# --- 1. Stage the bundle ------------------------------------------------------------
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp Resources/Info.plist "$STAGE/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$STAGE/Contents/Resources/"
fi
printf 'APPL????' > "$STAGE/Contents/PkgInfo"

# --- 2. Compile ---------------------------------------------------------------------
# Whole-module: ~20 files takes a couple of seconds, so no incremental machinery.
# Sources/Tools is excluded -- it holds the test entry point and the probes, each of
# which has its own top-level code.
#
# NUL-delimited so a path containing a space cannot word-split into two bad arguments.
SRC=()
while IFS= read -r -d '' f; do
    SRC+=("$f")
done < <(find Sources/App Sources/Core Sources/Services Sources/Views -name '*.swift' -print0)

if [ ${#SRC[@]} -eq 0 ]; then
    echo "No sources found under Sources/{App,Core,Services,Views}." >&2
    exit 1
fi

# Guard the rule the test target depends on: everything compiled by test.sh must import
# only Foundation and NaturalLanguage. Enforced here too so a violating import fails at
# the moment of the edit rather than as a link error several work items later.
./scripts/check-core-imports.sh

echo "sdk: $SDK"

swiftc -parse-as-library "$OPT" \
    -target "$TARGET" -sdk "$SDK" \
    -swift-version "$SWIFT_VERSION" \
    -module-name "$EXEC_NAME" \
    -o "$STAGE/Contents/MacOS/$EXEC_NAME" \
    "${SRC[@]}"

# --- 3. Lint the plist --------------------------------------------------------------
# A typo here is silent at launch and baffling later.
plutil -lint "$STAGE/Contents/Info.plist" >/dev/null

# --- 4. Sign ------------------------------------------------------------------------
# No --deep: there are no nested bundles, and it is deprecated.
# --options runtime enables the hardened runtime, which blocks DYLD_INSERT_LIBRARIES.
# Without it, any process running as this user can inject a dylib and use the
# microphone under this app's privacy grant. It works with a self-signed certificate;
# only notarization would need a Developer ID, and this app does not seek that.
#
# --entitlements is NOT optional once the runtime is on. The hardened runtime revokes
# access to protected resources unless the matching entitlement is present, so the two
# flags belong together: with the runtime and without the entitlements the microphone is
# refused outright, with no prompt and no row in System Settings to turn it back on. A
# usage string in Info.plist is necessary but not sufficient. Verified after the fact --
# the app was shipped this way and reported "microphone access is off" with nothing to
# switch on anywhere.
#
# Status is captured separately from output filtering. Piping into `grep -v` and
# appending `|| true` would discard codesign's exit status entirely, so a failed
# signature would install over a working app and present later as a dead microphone.
# Why this file has no comments in it: codesign hands entitlements to AMFI, whose parser
# is not a general plist reader. An XML comment fails with "AMFIUnserializeXML: syntax
# error near line 6" and the signature is refused. The explanation therefore lives here.
ENTITLEMENTS="Resources/OralEnglish.entitlements"
if [ ! -f "$ENTITLEMENTS" ]; then
    echo "Missing $ENTITLEMENTS. The hardened runtime would silently revoke the" >&2
    echo "microphone, so this is a hard failure rather than a warning." >&2
    exit 1
fi
plutil -lint "$ENTITLEMENTS" >/dev/null

if ! sign_out=$(codesign --force --sign "$SIGN_ID" \
        --identifier "$BUNDLE_ID" \
        --options runtime \
        --entitlements "$ENTITLEMENTS" \
        --timestamp=none "$STAGE" 2>&1); then
    printf '%s\n' "$sign_out" >&2
    echo "codesign failed. Not installing; the previous build is untouched." >&2
    exit 1
fi
printf '%s\n' "$sign_out" | grep -v 'replacing existing signature' || true

if ! verify_out=$(codesign --verify --verbose=2 "$STAGE" 2>&1); then
    printf '%s\n' "$verify_out" >&2
    echo "codesign --verify failed. Not installing; the previous build is untouched." >&2
    exit 1
fi
echo "signature verified"

# Assert we got the identity we asked for. An ad-hoc signature where a certificate was
# expected is the exact condition that makes privacy grants evaporate on rebuild.
if [ "$SIGN_ID" != "-" ]; then
    # -dvv, not -dv: the Authority line only appears at the second verbosity level.
    # Verified by comparing a cert-signed and an ad-hoc binary.
    #
    # Capture first, then match. Piping straight into `grep -q` breaks under
    # `set -o pipefail`: grep exits as soon as it matches, codesign takes SIGPIPE, and the
    # pipeline reports failure on the success path -- which made this check reject a
    # correctly signed bundle.
    dump=$(codesign -dvv "$STAGE" 2>&1 || true)
    if ! printf '%s\n' "$dump" | grep -q '^Authority='; then
        echo "Bundle is ad-hoc signed but \"$SIGN_ID\" was requested." >&2
        echo "Privacy grants would not survive a rebuild. Refusing to install." >&2
        exit 1
    fi
fi

# The entitlement is the one thing that fails silently and at a distance: the build is
# clean, the signature verifies, the app launches, and the microphone is simply gone. So it
# is asserted here rather than trusted.
ents=$(codesign -d --entitlements - --xml "$STAGE" 2>/dev/null || true)
if ! printf '%s' "$ents" | grep -q 'com.apple.security.device.audio-input'; then
    echo "The signed bundle carries no audio-input entitlement." >&2
    echo "With --options runtime that means no microphone, no prompt, and no row in" >&2
    echo "System Settings to fix it. Refusing to install." >&2
    exit 1
fi
echo "audio-input entitlement present"

# --- 5. Install to the stable path --------------------------------------------------
rm -rf "$DEPLOY"
ditto "$STAGE" "$DEPLOY"

echo "built -> $DEPLOY"
final=$(codesign -dvv "$DEPLOY" 2>&1 || true)
printf '%s\n' "$final" | grep -E '^Identifier=|^Signature|^Authority=' || true
