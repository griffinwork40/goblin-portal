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
# FALSIFICATION (--falsify flag).
#   Delegates to check-directory-indicator-falsify.sh, which runs four mutants,
#   each against a full APFS clone of app/. Every mutant must cause exit 1;
#   any mutant that passes (exit 0) means the gate is blind to that defect.
#     M1  gate status update behind `guard let directory` — nil-dir remote never shown
#     M2  remove idempotency guard — new view installed on every call
#     M3  show indicator for .unavailable — transient state leaks into UI
#     M4  indicator inserted at stack index 0 (above git header) — wrong view order
#
# EXIT CONTRACT.
#   0 = all cases passed.
#   1 = real assertion failure.
#   2 = environmental (swiftc missing, build failed, objects missing, compile error,
#       harness crash before any case reported, or the harness binary exits 2).
#   Under --falsify: 0 = all mutants caused exit 1 (gate is sensitive); 1 = some mutant
#   passed (gate is blind); 2 = environmental (stale pattern, clone failure, …).
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
# Falsification mode (--falsify): delegate to the companion script.
# check-directory-indicator-falsify.sh runs each mutant against an APFS
# clone of app/ and exits 0 iff every mutant was caught (exit 1 from the clone).
# An empty-run (no mutants attempted) exits 2 there, not 0.
# -------------------------------------------------------------------------
FALSIFY_SCRIPT="$ROOT/Scripts/check-directory-indicator-falsify.sh"
[[ -x "$FALSIFY_SCRIPT" ]] || {
  echo "error: $FALSIFY_SCRIPT not found or not executable — falsify script missing." >&2
  exit 2; }

say "==> falsification mode — 4 mutants via APFS clones, each must exit 1"
QUIET="$QUIET" "$FALSIFY_SCRIPT"
exit $?
