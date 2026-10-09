#!/bin/bash
#
# Do Core Text and Metal draw THE SAME PIXELS? Renders fixed escape-sequence inputs through a
# real TerminalPane with each renderer, offscreen, and compares them pixel by pixel. The gate
# for patch 0012 (patches/swiftterm/0012-rasterize-color-glyphs-at-logical-size.patch, N4)
# and the regression net for every other glyph class.
#
# FOUR FILES, one concern each, for the 350-LOC ceiling (the check-git-status.sh split):
#   check-render-parity-harness.swift   the cases and their tolerances (copied to main.swift)
#   check-render-parity-capture.swift   build a real pane, capture either renderer's pixels
#   check-render-parity-cases.swift     the fixed inputs
#   check-render-parity-metrics.swift   diff / ink / bbox / best-shift / AA-fringe, in Swift
# No python, no PIL: CoreGraphics and Metal ship with macOS.
#
# CASES
#   a  determinism: the same input twice, fresh panes, 0 differing px in EACH renderer
#   b  FALSIFICATION: one changed character must differ, in each renderer, and only inside
#      its own cell (measured 143 px Core Text / 145 px Metal). A harness comparing the wrong
#      image, or nothing, fails here before any parity case can pass vacuously.
#   c  parity per content class -- ascii, box drawing, block elements, cjk, sgr+underlines.
#      Text: differing px only on glyph edges, best shift (0,0), ink bbox within 1px, Metal
#      ink 0.95-1.15x. Box/blocks: byte-identical. Every tolerance is justified where it is
#      asserted, in the harness.
#   d  emoji (N4): per 2-cell slot, Metal's ink bbox within 1px of Core Text's and ink total
#      within 3%. Without 0012 the bbox is 8px off and the ink 0.62-0.69x.
#   PINNED (known, unfixed, never silently loosened):
#      N5   Metal's `|` paints 1px into the row below; Core Text's does not.
#   A pinned case FAILS when the defect changes, fixed or worse, so the pin gets re-measured.
#   F10 (fixed by patch 0013, #151): combining mark after a wide CJK char now lands over the
#      wide glyph in BOTH renderers. The case is now a CORRECTNESS assertion: mark ink must
#      start inside the wide-glyph slot (x < 2*cellW). With 0013 reverted it FAILS; applied, PASSES.
#
# FALSIFICATION OF THE FIX (done by hand when 0012 landed; transcripts in the PR): with 0012
# reverted, the four emoji slot cases and the emoji-rows parity case FAIL (exit 1) and every
# other case passes; with it applied, everything passes.
#
# FALSIFICATION OF 0013 (transcripts in the 0013 PR): with 0013 reverted, the two
# "F10 mark placement" cases FAIL (mark at x >= 2*cellW-4, outside the wide glyph slot).
# With 0013 applied both PASS (mark inside the slot). The parity case for F10 passes either
# way (both renderers still agree), so the placement cases are the meaningful signal.
#
# WHAT IT CANNOT SEE
#   * On-screen compositing. Both captures skip the window server (no screen-capture
#     permission here); the layer is tagged sRGB (MacTerminalView.swift:460), so the raw
#     bytes are what gets shown, but that is an argument, not a measurement.
#   * 1x displays and fractional cells. It requires a 2x screen and exits 2 without one;
#     at the default font both cell dimensions are whole device pixels.
#   * Fonts other than the system monospace at 14pt, ligatures, and the caret (hidden on
#     purpose: it is a subview under Core Text and a quad under Metal).
#   * Whether either renderer is RIGHT for cases not specifically asserted. Parity means
#     both renderers agree, which is necessary but not sufficient. F10 (combining mark after
#     a wide char) now asserts correctness too (patch 0013, #151).
#
# Exit codes: 0 pass; 1 a real failure; 2 environmental (no toolchain, build failed, no
# GoblinPortal objects, harness would not compile, no Metal device, no 2x screen, a capture
# that could not be taken, harness died).
#
set -uo pipefail

QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1
say() { [[ "$QUIET" == "1" ]] || echo "$@"; }

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

command -v swiftc >/dev/null 2>&1 || { echo "error: swiftc not found -- no Swift toolchain on PATH." >&2; exit 2; }
[[ -d ../vendor/SwiftTerm ]] || { echo "error: vendor/SwiftTerm missing -- run ./Scripts/bootstrap-vendor.sh" >&2; exit 2; }

# The harness @testable-imports GoblinPortal and links its objects, so they must be built from
# the tree on disk, every time (vendored-module.sh explains why "skip if the .o exists" is the
# silent-failure shape). Swift Build is the backend that emits a merged SwiftTerm.o.
say "==> building (the harness links Goblin Portal's own objects and the vendored SwiftTerm.o)"
FLAGS=()
swift build --help 2>&1 | grep -q -- '--build-system' && FLAGS=(--build-system swiftbuild)
if ! swift build "${FLAGS[@]}" >"$TMP/build.log" 2>&1; then
  echo "error: swift build failed -- fix the build before trusting this gate." >&2
  grep -E 'error' "$TMP/build.log" | head -10 >&2
  exit 2
fi
PRODUCTS="$(swift build "${FLAGS[@]}" --show-bin-path 2>/dev/null)"
[[ -f "$PRODUCTS/SwiftTerm.o" ]] || { echo "error: $PRODUCTS/SwiftTerm.o absent after swift build." >&2; exit 2; }

# The -p.build objects are the ones swift build just wrote. A -testable.build directory can
# also exist and be STALE (the audit's P1 probe linked one and measured last week's code).
OBJS="$(find "$ROOT/.build/out/Intermediates.noindex" -type d \
  -path '*GoblinPortal.build/*/GoblinPortal-p.build/Objects-normal/*' 2>/dev/null | head -1)"
[[ -n "$OBJS" && -f "$OBJS/TerminalPane.o" ]] || {
  echo "error: no GoblinPortal-p.build objects under .build -- cannot link the real TerminalPane." >&2; exit 2; }

cp Scripts/check-render-parity-harness.swift "$TMP/main.swift"
# Compiled INTO the products dir: for a bare executable Bundle.main.bundleURL is its directory,
# and that is where MetalTerminalRenderer looks for SwiftTerm_SwiftTerm.bundle (the shader).
# Built anywhere else, every Metal case dies "shader source missing" for a reason that has
# nothing to do with rendering (check-display-link.sh learned the same thing).
BIN="$PRODUCTS/renderparity"
trap 'rm -rf "$TMP" "$BIN"' EXIT
# shellcheck disable=SC2046  # one argument per object file is the point
if ! swiftc -o "$BIN" "$TMP/main.swift" Scripts/check-render-parity-capture.swift \
    Scripts/check-render-parity-cases.swift Scripts/check-render-parity-metrics.swift \
    -I "$OBJS" -I "$PRODUCTS" -I "$PRODUCTS/include" -L "$PRODUCTS" \
    $(find "$OBJS" -maxdepth 1 -name '*.o' ! -name 'main.o') "$PRODUCTS/SwiftTerm.o" \
    -framework AppKit -framework Metal -framework MetalKit 2>"$TMP/compile.log"; then
  echo "error: the harness would not compile -- the gate cannot run." >&2
  sed 's/^/    /' "$TMP/compile.log" >&2
  exit 2
fi

say "==> rendering every case through Core Text and Metal (~40s, offscreen, takes no focus)"
"$BIN" >"$TMP/out" 2>"$TMP/err"; rc=$?
[[ "$QUIET" == "1" ]] && grep -E 'FAIL|ENV=' "$TMP/out" || cat "$TMP/out"

# The verdict is the harness's EXIT CODE, never a stdout substring (the check-ghostty-pane.sh
# lesson: forgiving a nonzero status because ALL-OK printed let a crash read as green).
case "$rc" in
  0) say "==> Core Text / Metal render parity OK"; exit 0 ;;
  1) echo "FAIL: render parity -- see the FAIL lines above." >&2; exit 1 ;;
  2) echo "✗ environmental: $(grep -o 'ENV=.*' "$TMP/out" | head -1) -- not a verdict" >&2; exit 2 ;;
  *) echo "✗ harness died (exit $rc) -- environmental, not a verdict" >&2
     sed 's/^/    /' "$TMP/err" | tail -20 >&2; exit 2 ;;
esac
