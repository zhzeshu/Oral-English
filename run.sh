#!/bin/bash
# Builds and launches the app.
#
# Always launches with `open`, never the binary directly. Running
# build/Oral English.app/Contents/MacOS/OralEnglish from a terminal gives the process the
# terminal's privacy identity, so the microphone prompt is attributed to the terminal and
# the grant does not carry over to a Finder launch.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh
open "$HOME/Applications/Oral English.app"
