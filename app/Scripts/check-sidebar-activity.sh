#!/bin/bash
#
# check-sidebar-activity.sh — gates the sidebar Explorer ↔ SCM activity switcher.
#
# WHAT IS UNDER TEST. `SpaceViewController+SidebarActivity.swift` and
# `SidebarActivitySwitcher.swift`. The activity switcher sits at the top of the
# sidebar's NSStackView and lets the user flip between the Explorer file tree and
# the Source Control panel.
#
# The Swift assertions live in `check-sidebar-activity-harness.swift`, compiled and
# linked here against GoblinPortal's own object files — same split as
# check-git-status.sh / check-git-status-harness.swift. That keeps both files
# under the 350-LOC ceiling.
#
# FIVE CASES (in the harness):
#   1. INITIAL-STATE — right after SCM install, exactly one group is visible and
#      it is Explorer. Regression check for C2.
#   2. VIEW SWAP — switchSidebarActivity(.scm) hides Explorer, shows SCM;
#      .explorer reverses. Falsification target: removing sidebarScrollView.isHidden=true
#      in showSCMViews() makes case 2 fail.
#   3. MENU-SELECTOR — reads showExplorerSidebar: and showSourceControlSidebar: from
#      the real built menu (View items by title), then walks firstResponder→nextResponder.
#      The CONTROL uses a bogus selector and must return nil.
#   4. BADGE COUNT — pushBadgeCount(7) shows "7"; pushBadgeCount(0) hides it.
#   5. NO-REPO — a Space on a non-git temp dir shows no switcher, tree visible.
#
# EXIT CONTRACT (T2 fix + exit-contract fix):
#   0 = all cases passed.
#   1 = real assertion failure.
#   2 = environmental (swiftc missing, build failed, objects missing, compile error,
#       harness crash before any case reported, or the harness binary exits 2).
#
# A harness crash or unexpected exit after any `ok` or `FAIL` line still uses the
# harness's own exit code. A harness that exits non-zero before printing any verdict
# line is treated as environmental (exit 2), not a real failure (exit 1).
#
# LINK INPUTS. GoblinPortal-p.build/Objects-normal/<arch>/*.o (minus main.o)
# plus SwiftTerm.o — same object-directory discovery as check-sidebar-toggle.sh.
#
# WHY IT NEEDS A WINDOW SERVER. Case 2 drives view-swap through the live sidebar
# stack. Case 3 walks the responder chain. Same offscreen `.accessory` policy as
# check-sidebar-toggle.sh — no focus steal, no Dock icon.
#
set -uo pipefail

QUIET="${QUIET:-0}"
say() { [[ "$QUIET" == "1" ]] || echo "$@"; }

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
PRODUCTS="$ROOT/.build/out/Products/Debug"
HARNESS="$ROOT/Scripts/check-sidebar-activity-harness.swift"

command -v swiftc >/dev/null 2>&1 || {
  echo "error: swiftc not found — no Swift toolchain on PATH." >&2; exit 2; }

[[ -f "$HARNESS" ]] || {
  echo "error: $HARNESS not found — harness file is missing." >&2; exit 2; }

BFLAGS=(); swift build --help 2>&1 | grep -q -- '--build-system' && BFLAGS=(--build-system swiftbuild)
say "==> building (the harness links Goblin Portal's own objects, so they must be current)"
if ! swift build "${BFLAGS[@]}" >/dev/null 2>&1; then
  echo "error: swift build failed — fix the build before running this gate." >&2
  swift build "${BFLAGS[@]}" 2>&1 | grep -E 'error' | head -10 >&2
  exit 2
fi

TOBJ="$(find "$ROOT/.build/out/Intermediates.noindex" -type d \
  -path '*/Debug/GoblinPortal-p.build/Objects-normal/*' 2>/dev/null | head -1)"
[[ -n "$TOBJ" && -f "$TOBJ/SpaceViewController+SidebarActivity.o" ]] || {
  echo "error: GoblinPortal objects not found (expected GoblinPortal-p.build," \
       "SpaceViewController+SidebarActivity.o)." >&2
  echo "  Run: swift build --build-system swiftbuild" >&2
  exit 2; }
[[ -e "$PRODUCTS/SwiftTerm.o" ]] || {
  echo "error: $PRODUCTS/SwiftTerm.o missing after build." >&2; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Two temp directories:
# - SPACE_ROOT: used for the main (repo-git) Space. Because this worktree IS inside
#   a git repo, we use a plain temp dir which is NOT inside any git repo.
# - NOGIT_ROOT: a temp dir guaranteed to have no .git anywhere above it.
# Both are created under /tmp (resolved to /private/tmp on macOS) to avoid any
# accidental repo discovery from the current working directory.
SPACE_ROOT="$(mktemp -d "$TMP/space-root.XXXXXX")"
NOGIT_ROOT="$(mktemp -d "$TMP/nogit-root.XXXXXX")"

# Copy the harness to main.swift so swiftc sees it as the entry point.
cp "$HARNESS" "$TMP/main.swift"

OBJS=$(ls "$TOBJ"/*.o | grep -v '/main\.o$' | tr '\n' ' ')
if ! swiftc -o "$TMP/sidebaractivity" "$TMP/main.swift" \
    -I "$TOBJ" -I "$PRODUCTS" -I "$PRODUCTS/include" -L "$PRODUCTS" \
    $OBJS "$PRODUCTS/SwiftTerm.o" \
    -framework AppKit 2>"$TMP/compile.log"; then
  echo "error: the harness would not compile — the gate cannot run." >&2
  echo "  If this names a missing member on SpaceViewController or SidebarActivitySwitcher," >&2
  echo "  the seam changed and check-sidebar-activity-harness.swift needs updating." >&2
  grep -E 'error' "$TMP/compile.log" | head -10 | sed 's/^/    /' >&2
  exit 2
fi

# EXIT-CONTRACT FIX: use the harness's own exit code as the authoritative verdict.
# A crash after an 'ok' line now exits 2 (environmental), not 1 (real failure):
# - exit 0 from the harness → gate passes (exit 0)
# - exit 1 from the harness → real assertion failure (exit 1)
# - exit 2 from the harness → harness reported an environmental failure (exit 2)
# - any other nonzero (signal crash, etc.) → environmental (exit 2)
# A crash before printing any ok/FAIL line is also exit 2 (environmental).
out="$("$TMP/sidebaractivity" "$SPACE_ROOT" "$NOGIT_ROOT" 2>&1)"; hstatus=$?
say "$out"

if [[ $hstatus -eq 0 ]]; then
  exit 0
elif [[ $hstatus -eq 1 ]]; then
  # Confirm at least one FAIL line was printed; if none, treat as environmental.
  if grep -q 'FAIL ' <<<"$out"; then
    exit 1
  else
    echo "error: harness exited 1 but printed no FAIL lines — treating as environmental." >&2
    exit 2
  fi
else
  # exit 2 or signal/crash: always environmental.
  echo "error: harness exited with status $hstatus — treating as environmental." >&2
  exit 2
fi
