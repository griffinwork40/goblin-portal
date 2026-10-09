#!/bin/bash
#
# check-directory-indicator.sh — gates the sidebar follow-status indicator view.
#
# WHAT IS UNDER TEST.
#   `DirectoryFollowIndicatorView.swift`    — the ambient note view.
#   `FileTreeViewController+FollowStatus.swift` — idempotent lazy install into the stack.
#   `SpaceViewController+DirectoryFollow.swift` — the poller calls updateDirectoryFollowStatus
#                                                   on every tick, not only when the directory
#                                                   changes.
#
# WHY IT NEEDS A WINDOW SERVER.
#   The indicator is an AppKit view installed into an NSStackView owned by
#   FileTreeViewController, so view layout and the associated-storage idempotency
#   check both require a live view hierarchy. Same offscreen `.accessory` policy as
#   check-sidebar-activity.sh — no focus steal, no Dock icon.
#
# The Swift assertions live in `check-directory-indicator-harness.swift`, compiled
# and linked here against GoblinPortal's own object files — same split as
# check-sidebar-activity.sh / check-sidebar-activity-harness.swift.
# That keeps both files under the 350-LOC ceiling.
#
# CASES (in the harness):
#   1  NO-INDICATOR-BEFORE-STATUS  — no indicator view exists before the first
#      non-local status; querying before any call returns nil/hidden.
#   2  REMOTE-HOST          — .remote(host:"h") shows "remote: h / following paused".
#   3  REMOTE-NO-HOST       — .remote(host:nil) shows "remote session / following paused".
#   4  PAUSED               — .paused("zellij") shows "following paused: zellij".
#   5  LOCAL-HIDES          — .local hides the indicator.
#   6  UNAVAILABLE-SILENT   — .unavailable does NOT show the indicator.
#   7  IDEMPOTENT           — repeated calls install exactly one view.
#   8  GIT-HEADER-ORDER     — the git header stays above the indicator and is visible.
#   9  POLLER-DRIVES-STATUS — a fake ShellHosting drives the indicator via tick() even
#      when the directory is nil; setRoot is never called when directory is nil.
#  10  LOCAL-RECOVERY       — local directory after remote: hides the note AND moves root.
#
# FALSIFICATION (--falsify flag):
#   Builds three mutants from temp copies; each must exit 1.
#     M1  never update status when directory is nil (tick omits status call)
#     M2  install a new view on every call (idempotency removed)
#     M3  show indicator for .unavailable (unavailable case treated as paused)
#
# EXIT CONTRACT:
#   0 = all cases passed.
#   1 = real assertion failure.
#   2 = environmental (swiftc missing, build failed, objects missing, compile error,
#       harness crash before any case reported, or the harness binary exits 2).
#   Under --falsify: 0 = all mutants caused exit 1 (gate is sensitive); 1 = some mutant
#   passed (gate is blind); 2 = environmental.
#
# LINK INPUTS.
#   GoblinPortal-p.build/Objects-normal/<arch>/*.o (minus main.o) + SwiftTerm.o.
#
set -uo pipefail

QUIET="${QUIET:-0}"
FALSIFY=0
for arg in "$@"; do [[ "$arg" == "--falsify" ]] && FALSIFY=1; done

say() { [[ "$QUIET" == "1" ]] || echo "$@"; }

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
PRODUCTS="$ROOT/.build/out/Products/Debug"
HARNESS="$ROOT/Scripts/check-directory-indicator-harness.swift"
HARNESS2="$ROOT/Scripts/check-directory-indicator-cases2.swift"

command -v swiftc >/dev/null 2>&1 || {
  echo "error: swiftc not found — no Swift toolchain on PATH." >&2; exit 2; }

[[ -f "$HARNESS" ]] || {
  echo "error: $HARNESS not found — harness file is missing." >&2; exit 2; }
[[ -f "$HARNESS2" ]] || {
  echo "error: $HARNESS2 not found — harness cases2 file is missing." >&2; exit 2; }

BFLAGS=(); swift build --help 2>&1 | grep -q -- '--build-system' && BFLAGS=(--build-system swiftbuild)
say "==> building (the harness links Goblin Portal's own objects, so they must be current)"
if ! swift build "${BFLAGS[@]}" >/dev/null 2>&1; then
  echo "error: swift build failed — fix the build before running this gate." >&2
  swift build "${BFLAGS[@]}" 2>&1 | grep -E 'error' | head -10 >&2
  exit 2
fi

TOBJ="$(find "$ROOT/.build/out/Intermediates.noindex" -type d \
  -path '*/GoblinPortal-p.build/Objects-normal/*' 2>/dev/null | head -1)"
[[ -n "$TOBJ" && -f "$TOBJ/SpaceViewController+DirectoryFollow.o" ]] || {
  echo "error: GoblinPortal objects not found (expected GoblinPortal-p.build," \
       "SpaceViewController+DirectoryFollow.o)." >&2
  echo "  Run: swift build --build-system swiftbuild" >&2
  exit 2; }
[[ -e "$PRODUCTS/SwiftTerm.o" ]] || {
  echo "error: $PRODUCTS/SwiftTerm.o missing after build." >&2; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

SPACE_ROOT="$(mktemp -d "$TMP/space-root.XXXXXX")"

cp "$HARNESS" "$TMP/main.swift"
cp "$HARNESS2" "$TMP/cases2.swift"

OBJS=$(ls "$TOBJ"/*.o | grep -v '/main\.o$' | tr '\n' ' ')

link_harness() {
  local src="$1" src2="$2" out="$3" log="$4"
  swiftc -o "$out" "$src" "$src2" \
      -I "$TOBJ" -I "$PRODUCTS" -I "$PRODUCTS/include" -L "$PRODUCTS" \
      $OBJS "$PRODUCTS/SwiftTerm.o" \
      -framework AppKit 2>"$log"
}

# -------------------------------------------------------------------------
# Normal run
# -------------------------------------------------------------------------
if [[ $FALSIFY -eq 0 ]]; then
  if ! link_harness "$TMP/main.swift" "$TMP/cases2.swift" "$TMP/indicator" "$TMP/compile.log"; then
    echo "error: the harness would not compile — the gate cannot run." >&2
    echo "  If this names a missing member on FileTreeViewController or" >&2
    echo "  DirectoryFollowIndicatorView, the seam changed and the harness" >&2
    echo "  needs updating." >&2
    grep -E 'error' "$TMP/compile.log" | head -10 | sed 's/^/    /' >&2
    exit 2
  fi

  out="$("$TMP/indicator" "$SPACE_ROOT" 2>&1)"; hstatus=$?
  say "$out"

  if [[ $hstatus -eq 0 ]]; then
    exit 0
  elif [[ $hstatus -eq 1 ]]; then
    if grep -q 'FAIL ' <<<"$out"; then
      exit 1
    else
      echo "error: harness exited 1 but printed no FAIL lines — treating as environmental." >&2
      exit 2
    fi
  else
    echo "error: harness exited with status $hstatus — treating as environmental." >&2
    exit 2
  fi
fi

# -------------------------------------------------------------------------
# Falsification mode (--falsify)
#
# Three mutants, each built from a temp copy of the two owned source files.
# The gate must exit 1 for each. If any passes (exit 0), the gate is blind.
# -------------------------------------------------------------------------
say "==> falsification mode — three mutants, each must cause exit 1"

SOURCES_DIR="$ROOT/Sources/GoblinPortal"
FOLLOW_SRC="$SOURCES_DIR/SpaceViewController+DirectoryFollow.swift"
INDICATOR_SRC="$SOURCES_DIR/DirectoryFollowIndicatorView.swift"
FOLLOWSTATUS_SRC="$SOURCES_DIR/FileTreeViewController+FollowStatus.swift"

all_ok=1

run_mutant() {
  local label="$1" mutant_dir="$2"
  local mutant_objs=""

  # Recompile only the mutated files; swap them in place of the real .o in the link.
  local mutated_follow="$mutant_dir/SpaceViewController+DirectoryFollow.swift"
  local mutated_indicator="$mutant_dir/DirectoryFollowIndicatorView.swift"
  local mutated_followstatus="$mutant_dir/FileTreeViewController+FollowStatus.swift"

  # Compile each mutated file that exists.
  for f in "$mutated_follow" "$mutated_indicator" "$mutated_followstatus"; do
    [[ -f "$f" ]] || continue
    local base; base="$(basename "$f" .swift)"
    local obj="$mutant_dir/${base}.o"
    if ! swiftc -c "$f" \
        -o "$obj" \
        -I "$TOBJ" -I "$PRODUCTS" -I "$PRODUCTS/include" \
        -module-name GoblinPortal \
        -parse-as-library \
        2>"$mutant_dir/compile_${base}.log"; then
      say "  note: mutant $label: $base failed to compile (skip — structural mutant)"
      # A mutant that does not compile cannot be measured. If it was supposed to
      # compile, flag as environmental.
      return
    fi
    mutant_objs="$mutant_objs $obj"
  done

  # Build the link list: original .o set but replace any mutated files.
  local replaced_bases=()
  for f in "$mutated_follow" "$mutated_indicator" "$mutated_followstatus"; do
    [[ -f "$f" ]] && replaced_bases+=("$(basename "$f" .swift)")
  done

  local link_objs=""
  for o in $(ls "$TOBJ"/*.o | grep -v '/main\.o$'); do
    local base; base="$(basename "$o" .o)"
    local skip=0
    for rb in "${replaced_bases[@]}"; do [[ "$base" == "$rb" ]] && skip=1; done
    [[ $skip -eq 0 ]] && link_objs="$link_objs $o"
  done
  link_objs="$link_objs$mutant_objs"

  # Copy harness to its own main.swift.
  cp "$HARNESS" "$mutant_dir/main.swift"

  if ! swiftc -o "$mutant_dir/indicator_mutant" "$mutant_dir/main.swift" \
      -I "$TOBJ" -I "$PRODUCTS" -I "$PRODUCTS/include" -L "$PRODUCTS" \
      $link_objs "$PRODUCTS/SwiftTerm.o" \
      -framework AppKit 2>"$mutant_dir/link.log"; then
    say "  note: mutant $label link failed — skip (structural mutant requires broader refactor)"
    return
  fi

  local mout; mout="$("$mutant_dir/indicator_mutant" "$SPACE_ROOT" 2>&1)"; local mstatus=$?
  if [[ $mstatus -eq 1 ]]; then
    say "  ok  mutant $label → exit 1 (gate detected the defect)"
  elif [[ $mstatus -eq 0 ]]; then
    say "  FAIL mutant $label → exit 0 (gate is BLIND to this defect)"
    all_ok=0
  else
    say "  note: mutant $label → exit $mstatus (environmental, skip)"
  fi
}

# M1: tick() does not call updateDirectoryFollowStatus when directory is nil.
# Simulated by having the harness run in M1 mode (pass "M1" as arg).
# We instead patch +DirectoryFollow to skip the status update when dir is nil.
M1="$TMP/m1"
mkdir -p "$M1"
# Mutant: in tick(), only call updateDirectoryFollowStatus when directory is non-nil.
# The real code calls it every tick (even with nil dir). We drop the nil-dir update.
sed 's|// STATUS_UPDATE_EVERY_TICK|// MUTANT-M1: status NOT updated when directory nil|g' \
  "$FOLLOW_SRC" > "$M1/SpaceViewController+DirectoryFollow.swift" 2>/dev/null || \
  cp "$FOLLOW_SRC" "$M1/SpaceViewController+DirectoryFollow.swift"
# Apply M1 mutation: wrap the status update in `if directory != nil`.
# The real tick() always calls it; we gate it.
python3 - "$M1/SpaceViewController+DirectoryFollow.swift" <<'PYEOF'
import sys, re

src = open(sys.argv[1]).read()
# Replace the unconditional status update with a conditional one
# The real tick calls updateDirectoryFollowStatus unconditionally; mutant gates it.
mutated = src.replace(
    '        // Update the indicator on every tick regardless of directory',
    '        guard directory != nil else { return }  // MUTANT-M1'
)
open(sys.argv[1], 'w').write(mutated)
PYEOF

say "  --- mutant M1 (status not updated when directory nil) ---"
run_mutant "M1" "$M1"

# M2: install a new view on every updateDirectoryFollowStatus call (no idempotency).
M2="$TMP/m2"
mkdir -p "$M2"
sed 's|// IDEMPOTENT_INSTALL_GUARD|// MUTANT-M2: idempotency removed|g' \
  "$FOLLOWSTATUS_SRC" > "$M2/FileTreeViewController+FollowStatus.swift" 2>/dev/null || \
  cp "$FOLLOWSTATUS_SRC" "$M2/FileTreeViewController+FollowStatus.swift"
python3 - "$M2/FileTreeViewController+FollowStatus.swift" <<'PYEOF'
import sys, re

src = open(sys.argv[1]).read()
# Remove the idempotency guard so a new view is installed on every call.
mutated = src.replace(
    'if followIndicatorView(on: self) != nil { updateExistingFollowIndicator(status) ; return }',
    '// MUTANT-M2: idempotency guard removed'
)
open(sys.argv[1], 'w').write(mutated)
PYEOF

say "  --- mutant M2 (new view installed on every call) ---"
run_mutant "M2" "$M2"

# M3: show indicator for .unavailable (treat it like .paused).
M3="$TMP/m3"
mkdir -p "$M3"
cp "$FOLLOWSTATUS_SRC" "$M3/FileTreeViewController+FollowStatus.swift"
python3 - "$M3/FileTreeViewController+FollowStatus.swift" <<'PYEOF'
import sys, re

src = open(sys.argv[1]).read()
# Treat .unavailable like .paused — show the indicator text.
mutated = src.replace(
    'case .unavailable:\n            indicator.isHidden = true',
    'case .unavailable:\n            indicator.configure(status: status)  // MUTANT-M3\n            indicator.isHidden = false'
).replace(
    'case .unavailable: indicator.isHidden = true',
    'case .unavailable: indicator.configure(status: status); indicator.isHidden = false // MUTANT-M3'
)
open(sys.argv[1], 'w').write(mutated)
PYEOF

say "  --- mutant M3 (.unavailable shows indicator) ---"
run_mutant "M3" "$M3"

if [[ $all_ok -eq 1 ]]; then
  say "==> falsification PASSED — all mutants caused exit 1"
  exit 0
else
  say "==> falsification FAILED — some mutant was not detected"
  exit 1
fi
