#!/bin/bash
# Enforces the one rule the whole test loop depends on: every file compiled by test.sh
# imports only Foundation and NaturalLanguage.
#
# Why this is a script and not a checklist item: build.sh compiles Core and Services as
# one module, so an `import AVFoundation` added to a Core file compiles cleanly in the app
# build and breaks only test.sh -- as a link error, later, far from the edit. Checked
# mechanically it fails at the moment of the violating change instead.
#
# Adding a genuinely pure dependency means adding one line to ALLOWED below, which is a
# decision worth pausing on.
set -euo pipefail
cd "$(dirname "$0")/.."

ALLOWED="Foundation NaturalLanguage Testing"
TREES="Sources/Core Tests"
violations=0

for tree in $TREES; do
    [ -d "$tree" ] || continue
    while IFS= read -r -d '' f; do
        while IFS= read -r line; do
            mod=$(printf '%s\n' "$line" | sed -E 's/^[[:space:]]*(@[a-zA-Z]+[[:space:]]+)?import[[:space:]]+([A-Za-z_][A-Za-z0-9_]*).*/\2/')
            ok=0
            for a in $ALLOWED; do
                [ "$mod" = "$a" ] && ok=1 && break
            done
            if [ "$ok" -eq 0 ]; then
                echo "$f: imports '$mod', which is not allowed in $tree" >&2
                violations=$((violations + 1))
            fi
        done < <(grep -E '^[[:space:]]*(@[a-zA-Z]+[[:space:]]+)?import[[:space:]]+' "$f" || true)
    done < <(find "$tree" -name '*.swift' -print0)
done

if [ "$violations" -gt 0 ]; then
    cat >&2 <<MSG

$violations disallowed import(s). Sources/Core and Tests must import only: $ALLOWED

This is what lets test.sh compile the logic with no frameworks and no permission
prompts. Anything needing AVFoundation, Speech, SwiftUI or AppKit belongs in
Sources/Services or Sources/Views, behind a protocol whose pure half lives in Core.
MSG
    exit 1
fi
