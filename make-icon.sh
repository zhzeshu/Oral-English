#!/bin/bash
# Renders Resources/AppIcon.icns from Sources/Icon/MakeIcon.swift.
#
# Separate from build.sh on purpose: the icon changes about once, and re-rendering ten PNGs
# on every build to produce a byte-identical file is waste. build.sh copies the .icns if it
# is there, so run this when the icon changes and commit the result.
set -euo pipefail
cd "$(dirname "$0")"

ICONSET="Resources/AppIcon.iconset"
ICNS="Resources/AppIcon.icns"
BIN="build/make-icon"

mkdir -p build Resources

echo "compiling the renderer"
# Links nothing from Sources/ — CoreGraphics and ImageIO only.
swiftc -O -swift-version 6 \
    -target arm64-apple-macos26.0 -sdk "$(xcrun --show-sdk-path)" \
    -framework CoreGraphics -framework ImageIO \
    -o "$BIN" Sources/Icon/MakeIcon.swift

echo "rendering"
rm -rf "$ICONSET"
"./$BIN" "$ICONSET"

echo "packing"
iconutil -c icns "$ICONSET" -o "$ICNS"

# iconutil exits 0 on some malformed sets, so confirm the result is real.
if [ ! -s "$ICNS" ]; then
    echo "FAILED: $ICNS is missing or empty" >&2
    exit 1
fi
# Round-trip it: convert back to an iconset and count what came out. `iconutil -c icns`
# has been seen to exit 0 on a set it silently dropped sizes from, so the only honest check
# is to read the result back.
BACK="build/AppIcon.verify.iconset"
rm -rf "$BACK"
iconutil -c iconset "$ICNS" -o "$BACK" 2>/dev/null || true
COUNT="$(find "$BACK" -name '*.png' 2>/dev/null | wc -l | tr -d ' ')"
echo "wrote $ICNS ($(stat -f%z "$ICNS") bytes, $COUNT sizes verified by round-trip)"
if [ "$COUNT" -lt 10 ]; then
    echo "WARNING: expected 10 sizes, round-trip found $COUNT" >&2
fi
echo "run ./build.sh to put it in the bundle"
