#!/bin/bash
#
# Does the terminal paint IN STEP WITH THE DISPLAY? The gate for patch 0010
# (patches/swiftterm/0010-pace-redraws-on-display-link.patch, MacDisplayLinkPacer.swift).
#
# Offscreen GUI gate, the shape of check-metal-renderer.sh: it links the vendored
# SwiftTerm.o into Scripts/check-display-link-harness.swift, puts a TerminalView in a
# borderless, fully transparent, click-through window ON A REAL SCREEN (a display link does
# not tick for a window on no screen; measured 0 ticks at x=-20000), and feeds it a small
# update on a strict GCD timer, the shape of an agent-afk ink reveal frame. A reference
# CADisplayLink on a sibling view records the actual vsyncs. It never activates the app,
# never takes focus, and draws nothing visible.
#
# WHAT IS MEASURED, per renderer (coretext AND metal, because the user runs metal):
#   draws     real paints: draw(_:) on Core Text, the MTKView delegate's draw(in:) on Metal
#   ph50      median circular distance of a paint from the mean vsync phase, in ms. A paint
#             issued on the display link sits at a fixed phase (~0.2-0.4ms here); upstream's
#             free-running asyncAfter is uniform over the period (~P/4, ~2ms at 120Hz).
#
# CASES
#   1  static: queuePendingDisplay and queueMetalDisplay both route through the pacer
#   2  16ms producer, each renderer: >=90% of frames painted, ph50 < 0.15 x period
#   3  33ms producer, each renderer: the same bounds
#   4  idle: after a burst, zero paints and the link PAUSED (no CPU at rest)
#   5  DEC 2026 synchronized output: zero paints inside the block, a paint within
#      3 periods of its end
#   6  reparent: a frame pending when the view changes window paints in < 50ms (the stall
#      watchdog is 100ms, so a stranded frame would read >= 100)
#   7  screen move (only with two displays): phase stays locked after moving the window to
#      the other display, whose refresh rate may differ
#   8  FALSIFICATION: case 2 re-run with SWIFTTERM_DISPLAY_LINK=0 (upstream's timer) MUST
#      FAIL. If the old path passes these bounds, the gate is blind and exits 1.
#
# Each stream case takes the MEDIAN of three runs, because this measures a live window
# server on a machine doing other work. Measured spread on an M-series MacBook Pro
# (120Hz panel + 144Hz external), 2026-09-27: paced ph50 0.15-0.40ms, timer ph50
# 1.34-2.10ms; paced draws 188/188 vs timer 94/188 for a 16ms producer.
#
# WHAT IT CANNOT SEE: whether motion LOOKS even to a person. It proves paints land at a
# fixed phase of the refresh and that none are dropped; the compositor, tmux and the eye
# are downstream of that. See the PR body for the eyeball check.
#
# Exit codes: 0 pass; 1 a real failure (or the falsification case passed: blind gate);
# 2 environmental (no toolchain, no window server, display link never ticked, no Metal
# device, build or harness compile failed, harness died).
#
set -uo pipefail

QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1
say() { [[ "$QUIET" == "1" ]] || echo "$@"; }

cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

command -v swiftc >/dev/null 2>&1 || { echo "error: swiftc not found." >&2; exit 2; }

ATV="../vendor/SwiftTerm/Sources/SwiftTerm/Apple/AppleTerminalView.swift"
PACER="../vendor/SwiftTerm/Sources/SwiftTerm/Mac/MacDisplayLinkPacer.swift"
[[ -f "$ATV" ]] || { echo "error: vendor/SwiftTerm missing — run ./Scripts/bootstrap-vendor.sh" >&2; exit 2; }

failures=0
fail() { echo "✗ FAIL: $*" >&2; failures=$((failures + 1)); }

# --- case 1: static wiring ------------------------------------------------------------
# Match the CALL, comments stripped: a grep for the bare name would also match the
# rationale comment beside it (the check-theme-contrast.sh lesson).
code_only() { sed -e 's://.*$::' "$1"; }
if [[ ! -f "$PACER" ]]; then
  fail "MacDisplayLinkPacer.swift absent — patch 0010 not applied"
else
  n_calls="$(code_only "$ATV" | grep -c 'requestDisplayLinkFrame(')"
  if [[ "$n_calls" -ge 2 ]]; then
    say "  ok  1  both redraw queues route through the display-link pacer ($n_calls call sites)"
  else
    fail "1  expected queuePendingDisplay AND queueMetalDisplay to call requestDisplayLinkFrame, found $n_calls"
  fi
fi

# --- build + harness ---------------------------------------------------------------------
. Scripts/vendored-module.sh
resolve_vendored_module          # sets PRODUCTS, or exits 2
cp Scripts/check-display-link-harness.swift "$TMP/main.swift"
# Compiled INTO the products dir, exactly as check-metal-renderer.sh does: for a bare
# executable Bundle.main.bundleURL is the containing directory, and that is where
# MetalTerminalRenderer's candidateBundles() looks for SwiftTerm_SwiftTerm.bundle. Built in
# $TMP, the Metal cases died with "shader source missing" (exit 2) for a reason that has
# nothing to do with pacing.
DLCHECK="$PRODUCTS/dlcheck"
trap 'rm -rf "$TMP" "$DLCHECK"' EXIT
if ! swiftc -O -o "$DLCHECK" "$TMP/main.swift" -I "$PRODUCTS" -L "$PRODUCTS" \
    "$PRODUCTS/SwiftTerm.o" -framework AppKit -framework Metal -framework MetalKit \
    2>"$TMP/compile.log"; then
  echo "error: the harness would not compile — the gate cannot run." >&2
  sed 's/^/    /' "$TMP/compile.log" >&2
  exit 2
fi

# run <env-pacing 0|1> <args...>  -> one result line on stdout, or exits 2
run() {
  local pace="$1"; shift
  local out rc
  out="$(SWIFTTERM_DISPLAY_LINK="$pace" "$DLCHECK" "$@" 2>"$TMP/err")"; rc=$?
  if [[ "$out" == *ENV=* ]]; then
    echo "✗ environmental: ${out#*ENV=} — not a verdict" >&2; exit 2
  fi
  if [[ "$rc" != "0" ]]; then
    echo "✗ harness died (exit $rc) on '$*' — environmental" >&2; sed 's/^/    /' "$TMP/err" >&2; exit 2
  fi
  echo "$out" | grep -E '^(STREAM|IDLE|SYNC|REPARENT|SCREENMOVE) ' | tail -1
}
field() { local v="${1#* $2=}"; echo "${v%% *}"; }   # field <line> <key>
median3() { printf '%s\n' "$@" | sort -g | sed -n 2p; }

# stream_verdict <pace> <renderer> <ms>  -> prints "ok|bad <summary>"
stream_verdict() {
  local d=() p=() ph=() per="" line
  for _ in 1 2 3; do
    line="$(run "$1" "$4" "$2" "$3" 2)" || exit 2
    d+=("$(awk -v a="$(field "$line" draws)" -v b="$(field "$line" produced)" 'BEGIN{printf "%.3f", a/b}')")
    ph+=("$(field "$line" phase_dev_p50)"); p+=("$(field "$line" int_p50)"); per="$(field "$line" period)"
  done
  local dr php ip
  dr="$(median3 "${d[@]}")"; php="$(median3 "${ph[@]}")"; ip="$(median3 "${p[@]}")"
  local ok
  ok="$(awk -v dr="$dr" -v ph="$php" -v per="$per" 'BEGIN{print (dr >= 0.9 && ph < 0.15*per) ? "ok" : "bad"}')"
  echo "$ok painted=${dr} ph50=${php}ms int_p50=${ip}ms period=${per}ms"
}

n=2
for ms in 16 33; do
  for r in coretext metal; do
    v="$(stream_verdict 1 "$r" "$ms" stream)" || exit 2
    if [[ "$v" == ok* ]]; then say "  ok  $n  ${ms}ms producer, $r: ${v#ok }"
    else fail "$n  ${ms}ms producer, $r: ${v#bad } (want painted>=0.9, ph50<0.15xperiod)"; fi
  done
  n=$((n + 1))
done

# --- case 4: idle -----------------------------------------------------------------------
for r in coretext metal; do
  line="$(run 1 idle "$r")" || exit 2
  if [[ "$(field "$line" draws)" == "0" && "$(field "$line" link_active)" == "false" ]]; then
    say "  ok  4  idle, $r: no paints, display link paused"
  else fail "4  idle, $r: $line (want draws=0 link_active=false)"; fi
done

# --- case 5: synchronized output (DEC mode 2026) -----------------------------------------
for r in coretext metal; do
  line="$(run 1 sync "$r")" || exit 2
  held="$(field "$line" held_draws)"; rel="$(field "$line" release_draws)"
  after="$(field "$line" first_after_ms)"; per="$(field "$line" period)"
  if [[ "$held" == "0" && "$rel" != "0" && "$after" != "none" ]] \
     && awk -v a="$after" -v p="$per" 'BEGIN{exit !(a <= 3*p)}'; then
    say "  ok  5  2026, $r: 0 paints inside the block, first paint ${after}ms after it ended"
  else fail "5  2026, $r: $line (want held_draws=0, a paint within 3 periods of the end)"; fi
done

# --- case 6: reparent -------------------------------------------------------------------
for r in coretext metal; do
  line="$(run 1 reparent "$r")" || exit 2
  after="$(field "$line" first_after_ms)"
  if [[ "$after" != "none" ]] && awk -v a="$after" 'BEGIN{exit !(a < 50)}'; then
    say "  ok  6  window change, $r: pending frame painted ${after}ms later"
  else fail "6  window change, $r: $line (want a paint < 50ms; >= 100 means the watchdog rescued a stranded frame)"; fi
done

# --- case 7: screen move ------------------------------------------------------------------
line="$(run 1 screenmove metal 16 2)" || exit 2
if [[ "$line" == *skip=* ]]; then
  say "  --  7  screen move: skipped (one display attached)"
else
  per="$(field "$line" period)"; ph="$(field "$line" phase_dev_p50)"
  if awk -v ph="$ph" -v p="$per" 'BEGIN{exit !(ph < 0.15*p)}'; then
    say "  ok  7  moved to display 2 (period ${per}ms): ph50=${ph}ms"
  else fail "7  after a screen move: $line (want ph50 < 0.15 x new period)"; fi
fi

# --- case 8: falsification ----------------------------------------------------------------
blind=0
for r in coretext metal; do
  v="$(stream_verdict 0 "$r" 16 stream)" || exit 2
  if [[ "$v" == ok* ]]; then
    blind=1; fail "8  BLIND: upstream's timer path PASSED the pacing bounds ($r: ${v#ok })"
  else
    say "  ok  8  falsification, $r: timer path fails the bounds as it must (${v#bad })"
  fi
done

if [[ "$failures" -gt 0 ]]; then
  [[ "$blind" == "1" ]] && echo "The gate cannot tell the two paths apart; its passes mean nothing." >&2
  echo "FAIL: $failures case(s)." >&2
  exit 1
fi
say "==> display-link pacing OK"
