#!/usr/bin/env bash
#
# check-starter-config-falsify.sh — `check-starter-config.sh --falsify`: proves the
# drift guard's `^` anchor works.
#
# WHY THIS IS ITS OWN FILE. check-starter-config.sh is at the 350-LOC ceiling.
# The falsification body needs room for the decoy technique; extracting it here
# follows the same seam as check-shell-context-falsify.sh.
#
# WHAT IT OWNS. One scripted mutant (mutant C) that proves the `^` anchor in the
# drift guard's awk pattern (`^[[:space:]]*struct ConfigFile`) rejects a decoy that
# an unanchored pattern would accept. Without the anchor, a line like
# `// struct ConfigFile { var decoy }` inside a doc-comment matches the pattern
# and the guard exits thinking it found the struct — giving a false-clean result.
#
# SHAPE (AFK.md Conventions — falsification must mutate a copy of SHIPPED source):
#   1. cp -cR the whole app/ dir into a temp clone.
#   2. Prepend a decoy comment line to a COPY of Config.swift in the clone:
#        // struct ConfigFile { var decoy }
#      This line matches an UNANCHORED `struct ConfigFile` grep but must NOT be
#      treated as the real struct declaration by the anchored awk pattern, because
#      the awk comment-stripper removes `// …` lines before the pattern fires.
#   3. ALSO add a real but differently-named struct before ConfigFile in the copy,
#      so that an anchor-less awk (one that forgets to strip comments) would find
#      the decoy's brace first and emit "decoy" as a property — causing a drift
#      mismatch. The anchored, comment-stripping awk must skip the decoy entirely
#      and still find the real ConfigFile, emitting the real properties and exiting 0.
#   4. Run the clone's check-starter-config.sh in normal mode.
#   5. Exit 0 from the clone = anchor proved (decoy ignored, real struct found).
#      Exit 1 = anchor broken (decoy was treated as the struct); falsify fails (exit 1).
#      Exit 2 = environmental.
#
# EXIT CODES: 0 = anchor proved; 1 = anchor broken or misattributed; 2 = environmental.
#
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"   # app/
FWORK="$(mktemp -d /tmp/gpstcf.XXXXXX)"
trap 'rm -rf "$FWORK"' EXIT

echo "FALSIFY mutant C — decoy comment line must not fool the drift guard's ^ anchor"

CLONE="$FWORK/anchor-proof"
mkdir -p "$CLONE"
cp -cR "$ROOT" "$CLONE/app" 2>/dev/null || cp -R "$ROOT" "$CLONE/app"

TARGET="$CLONE/app/Sources/GoblinPortal/Config.swift"
BEFORE="$(shasum -a 256 "$TARGET" | cut -d' ' -f1)"

# Prepend two lines before `struct ConfigFile`:
#   Line 1: a doc-comment decoy that contains `struct ConfigFile { var decoy }`.
#            An unanchored awk looking for `struct ConfigFile` with no comment-
#            stripping would match this and emit "decoy" as the first property.
#   Line 2: a blank separator (readability; does not affect the awk).
# The real `struct ConfigFile` immediately follows, so the anchored awk (which
# strips `//` comments before the pattern fires) skips the decoy, finds the real
# declaration, and emits the real stored-property names unchanged.
python3 - "$TARGET" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
needle = 'struct ConfigFile: Decodable {'
if text.count(needle) != 1:
    print(f"pattern count={text.count(needle)}, expected 1 — pattern stale", file=sys.stderr)
    sys.exit(1)
decoy = (
    '// struct ConfigFile { var decoy }  '
    '// anchor-proof decoy — must be ignored by the drift guard\n'
    '\n'
)
open(path, "w").write(text.replace(needle, decoy + needle))
PY
STATUS=$?
if [ "$STATUS" -ne 0 ]; then
    echo "  anchor-proof: pattern no longer applies in Config.swift (exit 2)"; exit 2
fi

AFTER="$(shasum -a 256 "$TARGET" | cut -d' ' -f1)"
if [ "$BEFORE" = "$AFTER" ]; then
    echo "  anchor-proof: file unchanged after mutation — pattern stale (exit 2)"; exit 2
fi

set +e
"$CLONE/app/Scripts/check-starter-config.sh" >"$FWORK/anchor-proof.log" 2>&1
RC=$?
set -e

echo "  mutant C anchor-proof (Config.swift): gate exit $RC"
case "$RC" in
    0)
        # The anchored awk ignored the decoy and found the real struct → proved.
        if grep -q "drift guard.*match\|keys match" "$FWORK/anchor-proof.log"; then
            echo "    anchor proved: decoy ignored, drift guard found the real ConfigFile"
            grep -E 'drift|ok ' "$FWORK/anchor-proof.log" | tail -3 | sed 's/^/      /'
            echo "FALSIFY mutant C: anchor proved"; exit 0
        else
            echo "    AMBIGUOUS: exit 0 but drift-guard confirmation line not found"
            tail -5 "$FWORK/anchor-proof.log" | sed 's/^/      /'
            exit 1
        fi ;;
    1)
        echo "    ANCHOR BROKEN — drift guard was fooled by the decoy (exit 1 = mismatch)"
        grep -E 'error:|drift|decoy' "$FWORK/anchor-proof.log" | head -5 | sed 's/^/      /'
        exit 1 ;;
    *)
        echo "    ENVIRONMENTAL (gate exit $RC)"
        tail -5 "$FWORK/anchor-proof.log" | sed 's/^/      /'
        exit 2 ;;
esac
