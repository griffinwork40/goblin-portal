#!/bin/bash
#
# Does the document area — and the sidebar's first control — stay out of the titlebar band
# when the content view extends under it (.fullSizeContentView), with zero change by default?
#
# THE BUG. With .fullSizeContentView, DocumentAreaViewController laid out against view.bounds
# and put row 0 28pt under the titlebar (measured on macOS 27: terminal maxY 708 vs
# contentLayoutRect.maxY 680). The recorded cause — "NSSplitViewController does not propagate
# safeAreaInsets.top" — was refuted by measurement: the inset IS propagated (32pt), the
# controller never read it. Fixed in DocumentAreaViewController+SafeArea.swift plus a KVO on
# contentLayoutRect, because a second Space's tab bar or the config banner moves that rect
# without resizing the view (+64pt overlap measured without the KVO). Evidence and numbers:
# .afk/plans/titlebar-reclaim-scope.md §1. Shipped code does NOT enable the flag; the harness
# forces it on a real SpaceWindowController, so this gate guards the reclaim-the-titlebar work.
#
# CASES (assertions in check-titlebar-layout-harness.swift):
#   C0 control — default mask: no .fullSizeContentView, contentLayoutRect == content bounds,
#      layoutTopInset == 0, row 0 below the titlebar; records the grid (rows x cols).
#   C1 forced .fullSizeContentView — row 0 below contentLayoutRect.maxY AND grid == C0.
#   C4 a second Space tabbed in (native tab bar) — no manual relayout; row 0 below the bar.
#   C5 a 36pt .bottom titlebar accessory (ConfigWarningBanner's attachment) — same.
#   C7 the sidebar's filter field sits below its own safe area and the traffic lights.
#   ISO the real com.griffinlong.goblin-portal domain is unchanged (delta vs a snapshot).
#   A case whose precondition does not hold (the tab bar did not shrink the layout rect, the
#   flag did not extend the content view) exits 2: it could not judge, so it cannot pass.
#
# --falsify: each mutant is applied to an APFS clone of the SHIPPED app/ (cp -cR), the gate
# re-runs there, and the mutant counts as caught only if it exits 1 WITH a FAIL line for its
# declared case. Wrong-case failure or exit 0 = missed (exit 1); a mutant whose pattern no
# longer applies, or a clone that will not build, = exit 2. A zero-mutant run exits 2.
#   m1 drop the top inset (lay out against view.bounds again)        -> C1
#   m2 drop the contentLayoutRect KVO install                         -> C4
#   m3 drop the sidebar stack's safe-area term                        -> C7
#
# EXIT: 0 pass; 1 real failure; 2 environmental. The verdict is the harness EXIT CODE.
# CANNOT SEE: pixels, full screen, macOS 14/15 (measured on 27 only), and the shipped default
# never sets the flag — so this guards a configuration no user can reach until it is wired.
#
set -uo pipefail

QUIET="${QUIET:-0}"
say() { [[ "$QUIET" == "1" ]] || echo "$@"; }
FALSIFY=0
for arg in "$@"; do [[ "$arg" == "--falsify" ]] && FALSIFY=1; done

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
PRODUCTS="$ROOT/.build/out/Products/Debug"
HARNESS="$ROOT/Scripts/check-titlebar-layout-harness.swift"
[[ -f "$HARNESS" ]] || { echo "error: $HARNESS missing." >&2; exit 2; }

command -v swiftc >/dev/null 2>&1 || {
  echo "error: swiftc not found — no Swift toolchain on PATH." >&2; exit 2; }

# ---- falsification ---------------------------------------------------------------------------
if [[ $FALSIFY -eq 1 ]]; then
  FT="$(mktemp -d)"; trap 'rm -rf "$FT"' EXIT
  VENDOR="$(cd "$ROOT/.." && pwd)/vendor"
  [[ -d "$VENDOR/SwiftTerm" ]] || { echo "error: vendor/SwiftTerm missing." >&2; exit 2; }
  SRC=Sources/GoblinPortal
  # label | file | perl substitution | declared case
  MUTANTS=(
    "m1|$SRC/DocumentAreaViewController.swift|s/full\.height - layoutTopInset/full.height/|C1"
    "m2|$SRC/DocumentAreaViewController.swift|s/\n        observeContentLayoutRect\(\)\n/\n/|C4"
    "m3|$SRC/FileTreeViewController.swift|s/sidebarTopInset \+ view\.safeAreaInsets\.top/sidebarTopInset/|C7"
  )
  ran=0; missed=0; envfail=0
  for m in "${MUTANTS[@]}"; do
    IFS='|' read -r label file subst want <<<"$m"
    dest="$FT/$label"; mkdir -p "$dest"
    # The clone carries .build too, so the mutant build is incremental (~10s).
    cp -cR "$ROOT" "$dest/app" 2>/dev/null || cp -R "$ROOT" "$dest/app" || {
      echo "  ENV  $label: clone failed"; envfail=1; continue; }
    ln -s "$VENDOR" "$dest/vendor"
    target="$dest/app/$file"
    before="$(cksum "$target")"
    perl -0pi -e "$subst" "$target"
    if [[ "$(cksum "$target")" == "$before" ]]; then
      echo "  ENV  $label: pattern no longer applies to $file — mutant cannot be judged"
      envfail=1; continue
    fi
    out="$(QUIET=0 "$dest/app/Scripts/check-titlebar-layout.sh" 2>&1)"; st=$?
    ran=$((ran + 1))
    if [[ $st -eq 2 ]]; then
      echo "  ENV  $label: mutant run was environmental (exit 2) — e.g. it would not compile"
      grep -E 'error|ENV' <<<"$out" | head -3 | sed 's/^/       /'
      envfail=1
    elif [[ $st -eq 1 ]] && grep -q "FAIL $want " <<<"$out"; then
      echo "  ok   $label caught by its declared case $want"
      grep "FAIL $want " <<<"$out" | head -1 | sed 's/^/       /'
    else
      echo "  MISS $label (exit $st) — declared case $want did not fail"
      grep 'FAIL ' <<<"$out" | head -3 | sed 's/^/       /'
      missed=1
    fi
  done
  [[ $ran -eq 0 ]] && { echo "error: zero mutants ran — falsification proves nothing." >&2; exit 2; }
  [[ $envfail -eq 1 ]] && exit 2
  [[ $missed -eq 1 ]] && exit 1
  say "all $ran mutants caught by their declared cases"
  exit 0
fi

# ---- normal run ------------------------------------------------------------------------------
BFLAGS=(); swift build --help 2>&1 | grep -q -- '--build-system' && BFLAGS=(--build-system swiftbuild)
say "==> building (the harness links Goblin Portal's own objects, so they must be current)"
if ! swift build "${BFLAGS[@]}" >/dev/null 2>&1; then
  echo "error: swift build failed — fix the build before running this gate." >&2
  swift build "${BFLAGS[@]}" 2>&1 | grep -E 'error' | head -10 >&2
  exit 2
fi

# Same object lookup as check-first-window.sh (N2: only the pinned backend writes -p.build).
TOBJ="$(find "$ROOT/.build/out/Intermediates.noindex" -type d \
  -path '*/Debug/GoblinPortal-p.build/Objects-normal/*' 2>/dev/null | head -1)"
[[ -n "$TOBJ" && -f "$TOBJ/DocumentAreaViewController.o" ]] || {
  echo "error: GoblinPortal objects not found under .build/out (expected GoblinPortal-p.build)." >&2
  exit 2; }
[[ -e "$PRODUCTS/SwiftTerm.o" ]] || { echo "error: $PRODUCTS/SwiftTerm.o missing." >&2; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/root"
# A bundle-less binary's UserDefaults.standard is named after the executable: a PID-named
# binary gets a domain no run has used, never the real GoblinPortal one (asserted as ISO).
BIN="gp-titlebar-layout-check-$$"
cp "$HARNESS" "$TMP/main.swift"

OBJS=$(ls "$TOBJ"/*.o | grep -v '/main\.o$' | tr '\n' ' ')
if ! swiftc -o "$TMP/$BIN" "$TMP/main.swift" \
    -I "$TOBJ" -I "$PRODUCTS" -I "$PRODUCTS/include" -L "$PRODUCTS" \
    $OBJS "$PRODUCTS/SwiftTerm.o" -framework AppKit 2>"$TMP/compile.log"; then
  echo "error: the harness would not compile — the gate cannot run." >&2
  grep -E 'error' "$TMP/compile.log" | head -10 | sed 's/^/    /' >&2
  exit 2
fi

out="$("$TMP/$BIN" "$TMP/root" 2>&1)"; status=$?
defaults delete "$BIN" >/dev/null 2>&1
rm -f "$HOME/Library/Preferences/$BIN.plist"
# Drop the app's own `[goblin-portal]`/`[diag]` stderr chatter, not verdicts.
say "$(grep -v '^\[' <<<"$out")"

if [[ $status -eq 0 ]]; then exit 0; fi
if [[ $status -eq 2 ]] || ! grep -q 'ok   \|FAIL ' <<<"$out"; then
  echo "error: harness could not judge the layout (exit $status) — treating as environmental." >&2
  exit 2
fi
exit 1
