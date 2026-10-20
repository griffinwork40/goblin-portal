#!/usr/bin/env bash
#
# check-palette-covers-menu-falsify.sh — `check-palette-covers-menu.sh --falsify`:
# proves the PART 2 key-hint check can fail.
#
# WHY THIS IS ITS OWN FILE. check-palette-covers-menu.sh is at the 350-LOC ceiling.
# The falsification body needs enough room to explain what it owns; extracting it here
# follows the same seam as check-shell-context-falsify.sh.
#
# WHAT IT OWNS. One scripted mutant that edits a COPY of the shipped source
# (CommandPalette+Commands.swift) — not the harness — and requires the PART 2
# hint-mismatch case to fail (exit 1). The harness is never touched.
#
# SHAPE (AFK.md Conventions — falsification must mutate a copy of SHIPPED source):
#   1. cp -cR the whole app/ dir (APFS copy-on-write; the clone's incremental build
#      reuses the real build's work).
#   2. Apply the mutation to the clone's CommandPalette+Commands.swift — not the
#      harness script — and verify the file's checksum changed (a no-op mutation
#      means the pattern went stale: environmental, exit 2).
#   3. Run the clone's check-palette-covers-menu.sh in normal mode.
#   4. Mutant exit 1 AND the declared expected output substring present = caught.
#      Exit 0 = NOT caught (falsify fails, exit 1). Exit 2 = environmental.
#
# EXIT CODES: 0 = mutant caught; 1 = NOT caught or misattributed; 2 = environmental.
#
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"   # app/
VENDOR="$(cd "$ROOT/../vendor" 2>/dev/null && pwd)" || { echo "ENV: no ../vendor"; exit 2; }
FWORK="$(mktemp -d /tmp/gppalf.XXXXXX)"
trap 'rm -rf "$FWORK"' EXIT

echo "FALSIFY PART 2 — key-hint mutant must be caught by the hint-mismatch case"

# -----------------------------------------------------------------------
# Mutant: change the "New Tab" key hint from "⌘T" to "⌘X" in a COPY of
# CommandPalette+Commands.swift (shipped source). The harness is untouched.
# The hint-mismatch case must report exit 1 with a mismatch for "New Tab".
# -----------------------------------------------------------------------
CLONE="$FWORK/hint-mismatch"
mkdir -p "$CLONE"
cp -cR "$ROOT" "$CLONE/app" 2>/dev/null || cp -R "$ROOT" "$CLONE/app"
ln -s "$VENDOR" "$CLONE/vendor"

TARGET="$CLONE/app/Sources/GoblinPortal/CommandPalette+Commands.swift"
BEFORE="$(shasum -a 256 "$TARGET" | cut -d' ' -f1)"

# Replace exactly the "New Tab" hint. The pattern matches the full PaletteCommand
# line so the replacement is unambiguous (count == 1 enforced by python3).
if ! python3 - "$TARGET" \
    'PaletteCommand("New Tab",                     key: "⌘T",' \
    'PaletteCommand("New Tab",                     key: "⌘X",' <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path).read()
if text.count(old) != 1:
    print(f"  pattern count={text.count(old)}, expected 1 — pattern stale", file=sys.stderr)
    sys.exit(1)
open(path, "w").write(text.replace(old, new))
PY
then
    echo "  hint-mismatch: pattern no longer applies in CommandPalette+Commands.swift (exit 2)"
    exit 2
fi

AFTER="$(shasum -a 256 "$TARGET" | cut -d' ' -f1)"
if [ "$BEFORE" = "$AFTER" ]; then
    echo "  hint-mismatch: file unchanged after mutation — pattern stale (exit 2)"
    exit 2
fi

set +e
"$CLONE/app/Scripts/check-palette-covers-menu.sh" >"$FWORK/hint-mismatch.log" 2>&1
RC=$?
set -e

echo "  mutant hint-mismatch (CommandPalette+Commands.swift): gate exit $RC"
case "$RC" in
    1)
        if grep -q "FAIL.*New Tab\|New Tab.*FAIL\|'New Tab'" "$FWORK/hint-mismatch.log"; then
            echo "    caught by hint-mismatch case: 'New Tab' hint reported mismatched"
            grep "New Tab" "$FWORK/hint-mismatch.log" | head -3 | sed 's/^/      /'
            echo "FALSIFY PART 2: mutant caught"; exit 0
        else
            echo "    MISATTRIBUTED: exit 1 but 'New Tab' mismatch not in output"
            grep -E 'FAIL|ok ' "$FWORK/hint-mismatch.log" | head -5 | sed 's/^/      /'
            exit 1
        fi ;;
    0)
        echo "    NOT CAUGHT — the hint-mismatch case did not fire"
        grep -E 'ok |FAIL' "$FWORK/hint-mismatch.log" | head -5 | sed 's/^/      /'
        exit 1 ;;
    *)
        echo "    ENVIRONMENTAL (gate exit $RC)"
        tail -5 "$FWORK/hint-mismatch.log" | sed 's/^/      /'
        exit 2 ;;
esac
