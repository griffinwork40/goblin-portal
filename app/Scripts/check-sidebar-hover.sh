#!/bin/bash
#
# Does `"sidebar": { "revealOnHover": false }` actually stop a collapsed sidebar from sliding in
# at the left edge in full screen?
#
# WHAT IS UNDER TEST. `SpaceViewController+SidebarHover.swift` pushes `config.sidebarRevealOnHover`
# onto AppKit's `NSSplitViewItem.revealsOnEdgeHoverInFullscreen` (absent from the public header,
# set by KVC after a `responds(to:)` check). It is called from `SpaceWindowController.init` and
# `AppDelegate.reloadConfig`. The harness (`check-sidebar-hover-harness.swift`) drives a REAL
# offscreen SpaceWindowController:
#   H0  ENV: the accessor exists on this macOS (else exit 2, not a pass).
#   H1  DEFAULT: an untouched config leaves the flag true (no silent behaviour change).
#   H2  OFF AT INIT: revealOnHover=false reaches the item through init alone, and with the sidebar
#       collapsed the split controller's own `_hasItemToRevealOnEdgeHover` reads false.
#   H3  RELOAD ON + CONTROL: the same two reads come back true, so H2's false is not a stuck probe.
#   H4  RELOAD OFF: the live path turns it off again.
# Plus comment-stripped wiring greps, because the harness cannot run AppConfig.load() (it reads
# ~/.config via homeDirectoryForCurrentUser, which ignores $HOME, so it would read the operator's
# real file) nor AppDelegate.reloadConfig (it reads that same file):
#   W1  Config+Load.swift copies `revealOnHover` into `sidebarRevealOnHover`.
#   W2  SpaceWindowController.swift calls applySidebarHoverReveal() after contentViewController.
#   W3  AppDelegate.swift's reloadConfig calls applySidebarHoverReveal().
#
# --falsify: four mutants on an APFS clone of app/ (shipped source is never touched), each
# counted only when ITS declared case fails (a different case failing is WRONG-CASE = missed):
#   m1  setValue line deleted from +SidebarHover.swift      -> must fail H2
#   m2  init call deleted from SpaceWindowController.swift  -> must fail H2 (and W2)
#   m3  revealOnHover parse deleted from Config+Load.swift  -> must fail W1
#   m4  reload call deleted from AppDelegate.swift          -> must fail W3
# A mutant whose pattern no longer applies, or that does not build, exits 2.
#
# WHAT THIS CANNOT SEE: an actual pointer at the edge of an actual full-screen window. Entering
# full screen takes over a display and real edge hover needs a real cursor; both are daily-drive.
# The gate stops at AppKit's own derived state, one step short of the pixels.
#
# EXIT: 0 all passed; 1 a real failure; 2 environmental. The exit code is the verdict.
#
set -uo pipefail

QUIET="${QUIET:-0}"
say() { [[ "$QUIET" == "1" ]] || echo "$@"; }
FALSIFY=0; [[ "${1:-}" == "--falsify" ]] && FALSIFY=1

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
HARNESS="$ROOT/Scripts/check-sidebar-hover-harness.swift"
command -v swiftc >/dev/null 2>&1 || { echo "error: swiftc not found." >&2; exit 2; }
BFLAGS=(); swift build --help 2>&1 | grep -q -- '--build-system' && BFLAGS=(--build-system swiftbuild)

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
SPACE_ROOT="$TMP/space-root"; mkdir -p "$SPACE_ROOT"

# Strip // comments so a grep cannot be satisfied by prose.
code() { sed -E 's#//.*$##' "$1"; }

# wiring APPDIR -> prints FAIL lines, returns count
wiring() {
  local src="$1/Sources/GoblinPortal" n=0
  if code "$src/Config+Load.swift" | grep -q 'revealOnHover.*sidebarRevealOnHover'; then echo "  ok   W1: Config+Load parses revealOnHover"
  else echo "  FAIL W1: Config+Load.swift never copies revealOnHover into sidebarRevealOnHover"; n=$((n+1)); fi
  if code "$src/SpaceWindowController.swift" | awk '/contentViewController = space/{s=1} s && /applySidebarHoverReveal\(\)/{f=1} END{exit !f}'; then
    echo "  ok   W2: SpaceWindowController.init applies it after the view loads"
  else echo "  FAIL W2: SpaceWindowController.swift does not call applySidebarHoverReveal() after contentViewController"; n=$((n+1)); fi
  if code "$src/AppDelegate.swift" | awk '/func reloadConfig/{s=1} s && /applySidebarHoverReveal\(\)/{f=1} s && /^    }/{s=0} END{exit !f}'; then
    echo "  ok   W3: reloadConfig re-applies it (CmdR, Settings Apply)"
  else echo "  FAIL W3: AppDelegate.reloadConfig does not call applySidebarHoverReveal()"; n=$((n+1)); fi
  return $n
}

# run APPDIR LABEL -> builds, runs harness + wiring; echoes combined output; returns 0/1/2
run() {
  local app="$1" label="$2"
  if ! (cd "$app" && swift build "${BFLAGS[@]}" >/dev/null 2>&1); then
    echo "  ENV  swift build failed ($label)"; return 2; fi
  local products="$app/.build/out/Products/Debug"
  local tobj; tobj="$(find "$app/.build/out/Intermediates.noindex" -type d \
    -path '*/Debug/GoblinPortal-p.build/Objects-normal/*' 2>/dev/null -print -quit)"
  [[ -n "$tobj" && -f "$tobj/SpaceViewController+SidebarHover.o" && -e "$products/SwiftTerm.o" ]] || {
    echo "  ENV  objects not found ($label)"; return 2; }
  local objs; objs=$(ls "$tobj"/*.o | grep -v '/main\.o$' | tr '\n' ' ')
  if ! swiftc -o "$TMP/h-$label" "$HARNESS" -I "$tobj" -I "$products" -I "$products/include" \
      -L "$products" $objs "$products/SwiftTerm.o" -framework AppKit 2>"$TMP/c-$label.log"; then
    echo "  ENV  harness would not compile ($label)"; grep error "$TMP/c-$label.log" | head -5; return 2; fi
  local out st; out="$("$TMP/h-$label" "$SPACE_ROOT" 2>&1)"; st=$?
  echo "$out"
  [[ $st -eq 2 ]] && return 2
  [[ $st -ne 0 ]] && ! grep -q 'FAIL ' <<<"$out" && { echo "  ENV  harness died (exit $st)"; return 2; }
  wiring "$app"; local w=$?
  [[ $st -eq 0 && $w -eq 0 ]] && return 0 || return 1
}

say "==> shipped source"
out="$(run "$ROOT" shipped)"; status=$?
say "$out"
[[ $status -ne 0 ]] && { [[ $status -eq 2 ]] && echo "error: environmental — cannot judge." >&2; exit $status; }
say "all sidebar-hover checks passed"
[[ $FALSIFY -eq 0 ]] && exit 0

# ---------------------------------------------------------------- falsification
CLONE_ROOT="$TMP/clone"; mkdir -p "$CLONE_ROOT"
ln -sfn "$(cd "$ROOT/.." && pwd)/vendor" "$CLONE_ROOT/vendor"
caught=0; total=0
mutant() {  # name file perl-expr expected-case
  local name="$1" file="$2" expr="$3" want="$4" app="$CLONE_ROOT/app"
  rm -rf "$app"; cp -cR "$ROOT/" "$app/" 2>/dev/null || cp -R "$ROOT/" "$app/"
  local f="$app/Sources/GoblinPortal/$file"
  cp "$f" "$TMP/before"; perl -0pi -e "$expr" "$f"
  if cmp -s "$f" "$TMP/before"; then echo "error: mutant $name pattern no longer applies." >&2; exit 2; fi
  total=$((total+1))
  local mout mst; mout="$(run "$app" "$name")"; mst=$?
  [[ $mst -eq 2 ]] && { echo "$mout" >&2; echo "error: mutant $name environmental." >&2; exit 2; }
  if grep -q "FAIL $want:" <<<"$mout"; then say "  caught  $name (failed $want)"; caught=$((caught+1))
  elif [[ $mst -ne 0 ]]; then say "  WRONG-CASE $name (failed, but not $want)"; say "$mout"
  else say "  MISSED  $name (all green)"; fi
}
say ""; say "==> falsification (APFS clone; shipped source untouched)"
mutant m1 "SpaceViewController+SidebarHover.swift" 's/^\s*item\.setValue\(config\.sidebarRevealOnHover.*\n//m' H2
mutant m2 "SpaceWindowController.swift" 's/^\s*space\.applySidebarHoverReveal\(\).*\n//m' H2
mutant m3 "Config+Load.swift" 's/^\s*if let v = s\.revealOnHover.*\n//m' W1
mutant m4 "AppDelegate.swift" 's/^\s*controller\.space\.applySidebarHoverReveal\(\).*\n//m' W3
say "  $caught/$total mutants caught by their declared case"
[[ $total -eq 0 ]] && exit 2
[[ $caught -eq $total ]] && exit 0 || exit 1
