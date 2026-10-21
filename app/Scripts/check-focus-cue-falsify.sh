#!/bin/bash
#
# check-focus-cue-falsify.sh
# K4: notification path re-runs accent refresh; K4-CONTROL: falsification.
#
# SOURCED by check-focus-cue.sh after K1-K3 pass. All variables (ROOT, TMP, TOBJ,
# OBJS, PRODUCTS, BFLAGS, say) are inherited from the parent shell.
#
# WHY A SEPARATE FILE
#
# The 350-LOC ceiling (Scripts/check-file-size.sh, AFK.md) applies to Scripts/ files.
# check-focus-cue.sh reached that ceiling when K4 was added inline. The split follows
# the precedent set by verify-vendor-views.sh (sourced by verify-vendor.sh) and
# check-git-status-harness.swift (compiled by check-git-status.sh) — when the seam
# between two concerns falls exactly on the ceiling, pull the second concern out rather
# than shaving comments.
#
# K4 WHAT IS UNDER TEST
#
# SpaceViewController+FocusCue.swift — subscribeToSystemColorChanges() installs a
# NotificationCenter observer for NSColor.systemColorsDidChangeNotification that calls
# updateSplitDimming, which calls updateFocusCue with config.effectiveAccent. K4
# proves the full path fires when the notification is posted: the SHIPPED observer
# repairs a sentinel border colour back to the accent value, with NO test observer
# installed. The harness logic lives in check-focus-cue-k4.swift.
#
# K4-CONTROL (FALSIFICATION)
#
# Per AFK.md Conventions: "Falsification must mutate a copy of SHIPPED source. Use
# `cp -cR app/ <tmpdir>/app/` (APFS clonefile) and apply the mutant to the copy."
#
# The app/ directory (including .build via clonefile for an incremental rebuild) is
# cloned into $TMP/mutant_clone/. subscribeToSystemColorChanges() is emptied in the
# CLONE's +FocusCue.swift — the shipped file is never touched. The clone is rebuilt;
# the K4 harness is linked against the clone's objects. Part A is disabled via
# SKIP_PART_A=1 so the falsification proves Part B ALONE fails for the mutant
# (a mutant caught only by Part A does not count). The mutant must exit 1 because
# Part B fails: the sentinel border colour is never repaired because no observer fires.
#
# vendor/SwiftTerm lives at ../vendor relative to app/. The clone's Package.swift
# uses `../vendor/SwiftTerm` so we place the clone at $TMP/mutant_clone/app/ and
# symlink $TMP/mutant_clone/vendor -> <real vendor path>, keeping the relative path
# resolution correct without copying the vendor tree.
#
# VERDICT IS THE EXIT CODE — never a stdout substring.
#
set -uo pipefail

K4_SRC="$ROOT/Scripts/check-focus-cue-k4.swift"
[[ -f "$K4_SRC" ]] || { echo "error: $K4_SRC not found." >&2; exit 2; }

# ---------------------------------------------------------------------------
# K4 — shipped binary
# ---------------------------------------------------------------------------
if ! swiftc -o "$TMP/focus_cue_k4" "$K4_SRC" \
    -I "$TOBJ" -I "$PRODUCTS" -I "$PRODUCTS/include" -L "$PRODUCTS" \
    $OBJS "$PRODUCTS/SwiftTerm.o" \
    -framework AppKit 2>"$TMP/k4_compile.log"; then
  echo "error: K4 harness would not compile." >&2
  grep -E 'error' "$TMP/k4_compile.log" | head -10 | sed 's/^/    /' >&2; exit 2
fi

k4_out="$("$TMP/focus_cue_k4" 2>&1)"; k4_status=$?
say "$k4_out"
if [[ $k4_status -ne 0 ]]; then
  say ""; say "K4 FAILED — notification path did not update border colour."; exit 1
fi

# ---------------------------------------------------------------------------
# K4-CONTROL — mutant: subscribeToSystemColorChanges() body emptied.
#
# AFK.md Conventions: mutate a COPY, never the shipped source.
# Clone app/ with APFS clonefile so the .build dir is cheap to copy and
# the rebuild is incremental. Symlink vendor so Package.swift's relative
# `../vendor/SwiftTerm` resolves correctly from the clone's app/ directory.
# ---------------------------------------------------------------------------
say ""
say "==> K4-CONTROL: cloning app/ and mutating the copy …"

CLONE_ROOT="$TMP/mutant_clone"
CLONE_APP="$CLONE_ROOT/app"
REAL_VENDOR="$(cd "$ROOT/.." && pwd)/vendor"

mkdir -p "$CLONE_ROOT"

# APFS clonefile — fast and incremental for .build/.
if ! cp -cR "$ROOT/" "$CLONE_APP/" 2>/dev/null; then
  # Fallback for non-APFS filesystems (e.g. CI on Linux).
  cp -R "$ROOT/" "$CLONE_APP/"
fi

# Symlink vendor so `../vendor/SwiftTerm` resolves from CLONE_APP.
ln -sfn "$REAL_VENDOR" "$CLONE_ROOT/vendor"

CLONE_FOCUSCUE="$CLONE_APP/Sources/GoblinPortal/SpaceViewController+FocusCue.swift"
[[ -f "$CLONE_FOCUSCUE" ]] || {
  echo "error: clone did not produce $CLONE_FOCUSCUE" >&2; exit 2; }

# Empty subscribeToSystemColorChanges() body in the CLONE — shipped file untouched.
python3 - "$CLONE_FOCUSCUE" <<'PY'
import sys, re
src = open(sys.argv[1]).read()
patched = re.sub(
    r'(func subscribeToSystemColorChanges\(\) \{).*?(\n    \})',
    r'\1\2', src, flags=re.DOTALL, count=1)
open(sys.argv[1], 'w').write(patched)
PY

# Verify the observer assignment is gone from the clone.
if grep -q '= NotificationCenter.default.addObserver(' "$CLONE_FOCUSCUE"; then
  echo "error: mutation did not remove the observer from clone — K4-CONTROL is invalid." >&2
  exit 2
fi
say "  mutant: subscribeToSystemColorChanges() body emptied in clone"

# Verify shipped source is untouched.
SHIPPED_FOCUSCUE="$ROOT/Sources/GoblinPortal/SpaceViewController+FocusCue.swift"
if ! grep -q '= NotificationCenter.default.addObserver(' "$SHIPPED_FOCUSCUE"; then
  echo "error: shipped +FocusCue.swift was modified — falsification convention violated." >&2
  exit 2
fi
say "  shipped source: untouched (confirmed)"

# Rebuild from the clone (incremental via clonefile .build).
say "  rebuilding from clone …"
if ! (cd "$CLONE_APP" && swift build "${BFLAGS[@]}" >/dev/null 2>&1); then
  echo "error: mutant build failed — K4-CONTROL invalid." >&2; exit 2
fi

# Locate clone's object directory.
MTOBJ="$(find "$CLONE_APP/.build/out/Intermediates.noindex" -type d \
  -path '*/Debug/GoblinPortal-p.build/Objects-normal/*' 2>/dev/null | head -1)"
[[ -n "$MTOBJ" ]] || {
  echo "error: clone object dir not found after build." >&2; exit 2; }

MOBJS=$(ls "$MTOBJ"/*.o | grep -v '/main\.o$' | tr '\n' ' ')
MPRODUCTS="$CLONE_APP/.build/out/Products/Debug"

# Link K4 harness against the clone's objects and SwiftTerm.
if ! swiftc -o "$TMP/focus_cue_k4_mutant" "$K4_SRC" \
    -I "$MTOBJ" -I "$MPRODUCTS" -I "$MPRODUCTS/include" -L "$MPRODUCTS" \
    $MOBJS "$MPRODUCTS/SwiftTerm.o" \
    -framework AppKit 2>"$TMP/k4m_compile.log"; then
  echo "error: K4 mutant harness would not compile." >&2
  grep -E 'error' "$TMP/k4m_compile.log" | head -5 | sed 's/^/    /' >&2; exit 2
fi

# Run with SKIP_PART_A=1: Part B alone must catch the mutant.
# The mutant registered no observer, so the sentinel colour is never repaired → exit 1.
# FOCUS_CUE_SRC_PATH points at the mutant source for the (disabled) Part A grep.
k4m_out="$(SKIP_PART_A=1 \
    FOCUS_CUE_SRC_PATH="$CLONE_FOCUSCUE" \
    "$TMP/focus_cue_k4_mutant" 2>&1)"; k4m_status=$?
say "  mutant run (Part A disabled — Part B alone must fail):"
say "$k4m_out" | sed 's/^/    /'

if [[ $k4m_status -ne 0 ]]; then
  say "  ok   K4-CONTROL: mutant (no observer) failed K4 Part B — gate is not blind"
else
  say "  FAIL K4-CONTROL: mutant passed K4 when it should have failed — gate is blind"
  exit 1
fi

say ""
say "all focus-cue cases passed (K1 grow, K2 shrink, K3 control, K4 notification, K4-CONTROL)"
exit 0
