#!/bin/bash
#
# Are inline images ACTUALLY PAINTED, in the right cells, under BOTH renderers? (T4.4)
# check-render-parity.sh asserts Core Text == Metal, which a blank-on-both regression passes
# (its own header says so). This gate is absolute: per renderer, the expected colour fills the
# expected cell rectangle and nothing is inked just outside it.
#
# FILES: check-image-render-harness.swift (cases, copied to main.swift),
#        check-image-render-payloads.swift (OSC 1337 PNG, sixel, kitty APC G, marker), and the
#        render-parity capture + metrics files, reused unchanged (real TerminalPane, offscreen 2x).
# CASES (x coretext, metal): osc1337, sixel, kitty, altbuffer (painted in ?1049h, gone after
#        ?1049l), cursor-advance (text after a 2-row image lands 2 rows down, same column),
#        inline0-control (inline=0 is a download: nothing painted).
# --falsify: APFS clone (cp -cR) of app/ and vendor/, mutate the COPY, re-run this gate there.
#   m1 Metal otherImageDraws never appended   -> must fail osc1337-metal (Core Text stays green)
#   m2 Core Text non-kitty image draw skipped -> must fail osc1337-coretext
#   m3 ALWAYS-BLANK: both draw paths cut      -> must fail osc1337-coretext AND osc1337-metal
#   A mutant counts only when its declared case(s) fail; a pattern that no longer applies or a
#   mutant that will not build exits 2; zero mutants run exits 2.
# Exit codes: 0 pass; 1 assertion failed; 2 environmental (no toolchain/vendor, build or harness
# compile failed, no window server, no Metal device, no 2x screen, harness died).
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
command -v swiftc >/dev/null 2>&1 || { echo "error: swiftc not found" >&2; exit 2; }
[[ -d ../vendor/SwiftTerm ]] || { echo "error: vendor/SwiftTerm missing -- run ./Scripts/bootstrap-vendor.sh" >&2; exit 2; }

if [[ "${1:-}" == "--falsify" ]]; then
  VEN="Sources/SwiftTerm/Apple"
  MUTANTS=(
    "m1|$VEN/Metal/MetalTerminalRenderer.swift|s/otherImageDraws\.append(draw)/_ = draw/|osc1337-metal|osc1337-coretext"
    "m2|$VEN/AppleTerminalView.swift|s/if !otherImages\.isEmpty {/if false, !otherImages.isEmpty {/|osc1337-coretext|"
    "m3|both|BLANK|osc1337-coretext osc1337-metal|"
  )
  ran=0; caught=0; envfail=0
  for m in "${MUTANTS[@]}"; do
    IFS='|' read -r label file subst want green <<<"$m"
    dest="$TMP/$label"; mkdir -p "$dest"
    cp -cR "$ROOT" "$dest/app" && cp -cR "$ROOT/../vendor" "$dest/vendor" || { echo "  ENV  $label: clone failed"; envfail=1; continue; }
    chmod -R u+w "$dest/vendor/SwiftTerm/Sources"
    if [[ "$file" == "both" ]]; then
      files=("$VEN/Metal/MetalTerminalRenderer.swift" "$VEN/AppleTerminalView.swift")
      # { is literal in BRE (unescaped); \{ would start an interval expression and fail on macOS sed.
      substs=('s/otherImageDraws\.append(draw)/_ = draw/' 's/if !otherImages\.isEmpty {/if false, !otherImages.isEmpty {/')
    else files=("$file"); substs=("$subst"); fi
    applied=1
    for i in "${!files[@]}"; do
      t="$dest/vendor/SwiftTerm/${files[$i]}"; before="$(cksum <"$t")"
      # sed -i '' works here: both patterns are single-line (no cross-line slurp needed).
      # check-titlebar-layout.sh still uses perl -0pi; siblings are mixed -- alignment is best-effort.
      sed -i '' -e "${substs[$i]}" "$t"
      [[ "$(cksum <"$t")" == "$before" ]] && applied=0
    done
    if [[ $applied -eq 0 ]]; then echo "  ENV  $label: pattern no longer applies -- mutant cannot be judged"; envfail=1; continue; fi
    out="$("$dest/app/Scripts/check-image-render.sh" 2>&1)"; st=$?
    if [[ $st -eq 2 ]]; then
      echo "  ENV  $label: mutant run was environmental (exit 2)"; grep -E 'error|ENV' <<<"$out" | head -3 | sed 's/^/       /'
      envfail=1; continue
    fi
    ran=$((ran + 1)); ok=1
    for c in $want; do grep -q "FAIL $c " <<<"$out" || ok=0; done
    for c in $green; do grep -q "ok   $c " <<<"$out" || ok=0; done
    if [[ $st -eq 1 && $ok -eq 1 ]]; then
      caught=$((caught + 1)); echo "  ok   $label caught by $want${green:+ (with $green still green)}"
      grep -E "FAIL ($(tr ' ' '|' <<<"$want")) " <<<"$out" | head -2 | cut -c1-200 | sed 's/^/       /'
    else
      echo "  MISS $label (exit $st) -- declared case(s) $want did not fail as required"
      grep -E 'FAIL|ok  ' <<<"$out" | cut -c1-120 | sed 's/^/       /'
    fi
  done
  echo "==> falsify: $caught/$ran caught"
  [[ $envfail -eq 1 || $ran -eq 0 ]] && exit 2
  [[ $caught -eq $ran ]] && exit 0 || exit 1
fi

echo "==> building (links Goblin Portal's own objects and the vendored SwiftTerm.o)"
FLAGS=()
swift build --help 2>&1 | grep -q -- '--build-system' && FLAGS=(--build-system swiftbuild)
if ! swift build "${FLAGS[@]}" >"$TMP/build.log" 2>&1; then
  echo "error: swift build failed" >&2; grep -E 'error' "$TMP/build.log" | head -10 >&2; exit 2
fi
PRODUCTS="$(swift build "${FLAGS[@]}" --show-bin-path 2>/dev/null)"
[[ -f "$PRODUCTS/SwiftTerm.o" ]] || { echo "error: SwiftTerm.o absent after swift build" >&2; exit 2; }
OBJS="$(find "$ROOT/.build/out/Intermediates.noindex" -type d \
  -path '*GoblinPortal.build/Debug/GoblinPortal-p.build/Objects-normal/*' 2>/dev/null | head -1)"
[[ -n "$OBJS" && -f "$OBJS/TerminalPane.o" ]] || { echo "error: no GoblinPortal-p.build objects" >&2; exit 2; }
cp Scripts/check-image-render-harness.swift "$TMP/main.swift"
# Built INTO the products dir so MetalTerminalRenderer finds SwiftTerm_SwiftTerm.bundle (the
# shader) beside Bundle.main -- check-render-parity.sh's lesson.
BIN="$PRODUCTS/imagerender"
trap 'rm -rf "$TMP" "$BIN"' EXIT
# shellcheck disable=SC2046
if ! swiftc -o "$BIN" "$TMP/main.swift" Scripts/check-image-render-payloads.swift \
    Scripts/check-render-parity-capture.swift Scripts/check-render-parity-metrics.swift \
    -I "$OBJS" -I "$PRODUCTS" -I "$PRODUCTS/include" -L "$PRODUCTS" \
    $(find "$OBJS" -maxdepth 1 -name '*.o' ! -name 'main.o') "$PRODUCTS/SwiftTerm.o" \
    -framework AppKit -framework Metal -framework MetalKit 2>"$TMP/compile.log"; then
  echo "error: the harness would not compile" >&2; sed 's/^/    /' "$TMP/compile.log" >&2; exit 2
fi
echo "==> painting OSC 1337 / sixel / kitty through Core Text and Metal (offscreen, no focus)"
"$BIN" >"$TMP/out" 2>"$TMP/err"; rc=$?
cat "$TMP/out"
case "$rc" in
  0) echo "==> images painted correctly under both renderers"; exit 0 ;;
  1) echo "FAIL: image render -- see the FAIL lines above." >&2; exit 1 ;;
  2) echo "✗ environmental: $(grep -o 'ENV=.*' "$TMP/out" | head -1) -- not a verdict" >&2; exit 2 ;;
  *) echo "✗ harness died (exit $rc) -- environmental" >&2; tail -20 "$TMP/err" >&2; exit 2 ;;
esac
