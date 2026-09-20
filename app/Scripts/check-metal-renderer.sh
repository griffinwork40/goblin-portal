#!/bin/bash
#
# Assert the Metal GPU renderer is actually REACHABLE — statically (the shader ships) and
# behaviourally (asking for it succeeds).
#
# This is the gate for patches/swiftterm/0001-ship-metal-shader-as-copy-resource.patch and
# for SwiftTerm's own setUseMetal / isUsingMetalRenderer contract, which is what
# TerminalPane+Renderer.swift is built on top of.
#
# WHAT IT CANNOT TEST, stated here rather than left to be discovered — the same disclosure
# check-cwd-follow.sh makes about its own two blind spots.
#
#   * `Renderer.named` — the config-string mapping. Not here: it needs no Metal device, no
#     window server and no `swift build`, and bundling it into a gate that exits 2 when the
#     machine has no GPU would make the cheap headless check unavailable exactly when it is
#     most useful. It lives in its own script, check-renderer-config.sh. Every case below
#     calls setUseMetal directly and therefore bypasses that mapping entirely.
#   * `applyRenderer(_:)` — the wrapper. It is an extension on TerminalPane, which needs
#     AppKit, SwiftTerm and a live NSView, so it cannot be compiled standalone the way
#     Renderer.swift can. The cases below call the same `setUseMetal` it calls and do the
#     same readback, so they cover the CONTRACT it depends on, not the wrapper. In
#     particular they say nothing about WHEN applyRenderer runs relative to the view
#     entering a window, which is a real and separately-tracked gap.
#
# WHY IT EXISTS. Until 2026-07-31 patch 0001 used `exclude:` on Apple/Metal/Shaders.metal,
# which kept the file out of the resource bundle. MetalTerminalRenderer.makeLibrary
# (MetalTerminalRenderer.swift:2746) needs it there so it can compile the shader at RUNTIME
# (:2765) when no .metallib exists; without it, it throws shaderSourceMissing (:2762) and
# the view stays on Core Text. So the vendored GPU renderer was unreachable for the life of
# the project — and nothing said so, because everything still compiled and ran. That is the
# same silent asymmetry verify-vendor.sh exists to kill, and this is its equivalent one
# layer up: a config that says `"renderer": "metal"` while the app quietly draws with Core
# Text is worse than a config that fails, because it is indistinguishable from success.
#
# WHAT MAKES THIS GATE WORTH BELIEVING. A check that only ever asserts "metal works" would
# still pass if it were asserting something vacuous. Four behavioural cases guard against
# that, and case 4 is the load-bearing one:
#
#   1. request metal -> the view reports metal            (the thing we want)
#   2. request coretext -> the view reports coretext      (WEAK control: on a fresh view
#                                                          useMetalRenderer is already
#                                                          false, so setUseMetal early-
#                                                          returns — MacTerminalView.swift
#                                                          :379-381 — and this passes
#                                                          without any teardown running. It
#                                                          still falsifies "the harness
#                                                          ignores its argument", which is
#                                                          why it stays; it does not
#                                                          falsify "setUseMetal is a no-op")
#   3. metal THEN coretext in one process -> reports coretext
#                                                         (REAL control: the only case that
#                                                          makes the teardown path run, and
#                                                          the only one that would fail if
#                                                          setUseMetal were a no-op. This is
#                                                          also the path a ⌘R after editing
#                                                          `renderer` back to coretext takes)
#   4. HIDE the shader, request metal -> the view reports coretext AND setUseMetal throws
#                                                         (falsification: proves case 1
#                                                          passes BECAUSE of the shipped
#                                                          shader, not for some other
#                                                          reason — this is the exact
#                                                          pre-2026-07-31 state, recreated
#                                                          on purpose)
#
# Case 4 is what the retired ReflowGateTests never had, and what check-altbuffer-resize.sh
# added as its control. Without it, this script could pass on a machine where Metal happens
# to work via a stale default library and we would learn nothing about our own packaging.
#
# Usage:
#   ./Scripts/check-metal-renderer.sh            # build if needed, run all cases
#   ./Scripts/check-metal-renderer.sh --quiet    # summary line and failures only
#
# Exit codes:
#   0  the GPU renderer ships and is reachable
#   1  a real failure — the shader is missing from a bundle, or asking for Metal silently
#      falls back, or the falsification case did NOT fall back (the gate is blind)
#   2  environmental — no toolchain, no Metal device, no window server, build failed, or the
#      harness process itself died. Never conflated with 1: a broken environment must not
#      read as a green gate, and it must not read as a RED one either — a harness that
#      crashes is telling us about the machine, not about the renderer.

set -uo pipefail

QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1
say() { [[ "$QUIET" == "1" ]] || echo "$@"; }

cd "$(dirname "$0")/.."
APP_ROOT="$(pwd)"
PRODUCTS="$APP_ROOT/.build/out/Products/Debug"
RES_BUNDLE="$PRODUCTS/SwiftTerm_SwiftTerm.bundle"
TMP="$(mktemp -d)"
HIDDEN=""
cleanup() {
  # Restore the shader first and unconditionally: case 3 deliberately breaks the build
  # products, and leaving them broken would make the NEXT run of anything fail for a
  # reason that has nothing to do with its own subject.
  [[ -n "$HIDDEN" && -f "$HIDDEN" ]] && mv "$HIDDEN" "$RES_BUNDLE/Contents/Resources/Shaders.metal"
  rm -rf "$TMP"
}
trap cleanup EXIT

# --- environment -----------------------------------------------------------------
if ! command -v swiftc >/dev/null 2>&1; then
  echo "error: swiftc not found — no Swift toolchain on PATH." >&2
  exit 2
fi
say "==> building (needed: SwiftTerm.o and the resource bundle)"
if ! swift build >/dev/null 2>&1; then
  echo "error: swift build failed — fix that before trusting this gate." >&2
  exit 2
fi
if [[ ! -f "$PRODUCTS/SwiftTerm.o" ]]; then
  echo "error: $PRODUCTS/SwiftTerm.o absent after swift build." >&2
  exit 2
fi

# --- static case A: does the shader ship in the SwiftPM resource bundle? ----------
SHADER="$RES_BUNDLE/Contents/Resources/Shaders.metal"
if [[ ! -f "$SHADER" ]]; then
  echo "✗ FAIL: $SHADER is missing." >&2
  echo "  vendor/SwiftTerm/Package.swift is not declaring Apple/Metal/Shaders.metal as a" >&2
  echo "  .copy resource. Apply patch 0001:" >&2
  echo "    patch -p1 -d vendor/SwiftTerm < patches/swiftterm/0001-ship-metal-shader-as-copy-resource.patch" >&2
  echo "  Note it must be .copy, NOT upstream's .process — .process invokes the offline" >&2
  echo "  Metal compiler and dies with 'unable to spawn process metal' on a machine with" >&2
  echo "  only Command Line Tools installed." >&2
  exit 1
fi
say "  ok  shader in SwiftPM resource bundle"

# --- static case B: does the packaged .app carry it too? --------------------------
# The dev path (`swift run`) and the shipped path (`open build/GoblinPortal.app`) resolve the
# bundle from DIFFERENT places — Bundle.main.bundleURL versus Bundle.main.resourceURL
# (candidateBundles(), MetalTerminalRenderer.swift:2825) — so checking one proves nothing
# about the other. make-app-bundle.sh:51 is what carries it across; this asserts it did.
if ! ./Scripts/make-app-bundle.sh >/dev/null 2>&1; then
  echo "error: make-app-bundle.sh failed — cannot check the packaged path." >&2
  exit 2
fi
APP_SHADER="$APP_ROOT/build/Goblin Portal.app/Contents/Resources/SwiftTerm_SwiftTerm.bundle/Contents/Resources/Shaders.metal"
if [[ ! -f "$APP_SHADER" ]]; then
  echo "✗ FAIL: the shader is in the build products but NOT in Goblin Portal.app." >&2
  echo "  Expected: ${APP_SHADER#$APP_ROOT/}" >&2
  echo "  make-app-bundle.sh copies \$BIN_DIR/*.bundle into Contents/Resources (:51-53);" >&2
  echo "  if that loop changed, the shipped app has no reachable GPU renderer even though" >&2
  echo "  \`swift run\` does. That divergence is invisible in normal use." >&2
  exit 1
fi
say "  ok  shader in Goblin Portal.app/Contents/Resources"

failures=0

# --- the behavioural harness ------------------------------------------------------
cat > "$TMP/main.swift" <<'SWIFT'
import AppKit
import Metal
import SwiftTerm

// Offscreen and .accessory: a real window is needed for the view to lay out, a visible or
// focused one is not. Same posture as check-find-menu.sh — this must not steal focus.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

guard MTLCreateSystemDefaultDevice() != nil else {
    print("NO_METAL_DEVICE")
    exit(0)
}

let want = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "metal"

let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
let win = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 640, height: 400),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
win.contentView = view
win.makeKeyAndOrderFront(nil)
RunLoop.current.run(until: Date().addingTimeInterval(0.2))

// No process is started on purpose: this asks about the RENDERER, and a pty would add a
// second thing that can fail for reasons the gate is not about.
var threw = "none"
do {
    if want == "downgrade" {
        // The only case that makes the TEARDOWN path run. A freshly constructed view already
        // has useMetalRenderer == false, so `setUseMetal(false)` on its own early-returns
        // (MacTerminalView.swift:379-381) and asserts nothing — enable first, then disable,
        // so removing the MTKView and restoring the caret view is actually exercised. This is
        // also the path a ⌘R takes after `renderer` is edited back to coretext.
        try view.setUseMetal(true)
        try view.setUseMetal(false)
    } else {
        try view.setUseMetal(want == "metal")
    }
} catch {
    threw = "\(error)"
}
RunLoop.current.run(until: Date().addingTimeInterval(0.2))

// Read back from SwiftTerm rather than trusting the call — the same rule
// TerminalPane+Renderer.swift follows, for the same reason.
print("LIVE=\(view.isUsingMetalRenderer ? "metal" : "coretext") THREW=\(threw)")
SWIFT

if ! swiftc -O -o "$PRODUCTS/metalcheck" "$TMP/main.swift" \
    -I "$PRODUCTS" -L "$PRODUCTS" "$PRODUCTS/SwiftTerm.o" \
    -framework AppKit -framework Metal -framework MetalKit 2>"$TMP/compile.log"; then
  echo "error: the harness would not compile — the gate cannot run." >&2
  sed 's/^/    /' "$TMP/compile.log" >&2
  exit 2
fi
# Deliberately compiled INTO the products dir: Bundle.main.bundleURL is the containing
# directory for a bare executable, and that is one of the two paths candidateBundles()
# probes. Compiled anywhere else, the harness would fail to find the shader for a reason
# that has nothing to do with whether the shader ships.

# stderr is KEPT, not discarded. When the harness dies its stderr is the only useful thing it
# produced, and `2>/dev/null` was throwing exactly that away — leaving "expected metal, got
# CRASH" as the entire diagnosis. Truncated per case so the log always describes this run.
run_case() {
  : > "$TMP/harness.err"
  "$PRODUCTS/metalcheck" "$1" 2>"$TMP/harness.err" || echo "CRASH"
}

report() { # name expected_live actual_output
  local name="$1" expect="$2" out="$3"
  local live="${out#LIVE=}"; live="${live%% *}"
  if [[ "$out" == "NO_METAL_DEVICE" ]]; then
    echo "✗ no Metal device / no window server — environmental, not a verdict" >&2
    exit 2
  fi
  # A dead harness is a statement about the machine, not about the renderer. Exit 2, not 1:
  # letting it fall through to the comparison below scored it as a wrong renderer and exited
  # 1, which is the documented code for "a real failure" — the exact conflation the 1-vs-2
  # split exists to prevent, just pointing the other way.
  if [[ "$out" == "CRASH" ]]; then
    echo "✗ the harness died running case '$name' — environmental, not a verdict" >&2
    [[ -s "$TMP/harness.err" ]] && sed 's/^/    /' "$TMP/harness.err" >&2
    exit 2
  fi
  if [[ "$live" == "$expect" ]]; then
    say "  ok  $name -> $live"
  else
    echo "✗ FAIL: $name expected '$expect', got: $out" >&2
    failures=$((failures + 1))
  fi
}

say "==> behavioural cases"
report "request metal" "metal" "$(run_case metal)"
report "request coretext (weak control)" "coretext" "$(run_case coretext)"
report "metal -> coretext teardown (real control)" "coretext" "$(run_case downgrade)"

# --- case 4: falsification -------------------------------------------------------
# Recreate the pre-2026-07-31 state exactly — shader absent from the bundle — and require
# that asking for Metal now FAILS. If it still succeeds, this gate is not measuring our
# packaging and its other three cases mean nothing.
HIDDEN="$TMP/Shaders.metal.hidden"
mv "$SHADER" "$HIDDEN"
falsify_out="$(run_case metal)"
# Clear the sentinel ONLY if the restore actually worked. `set -e` is deliberately off (see
# the top of the file), so a failed `mv` here would otherwise fall straight through to
# `HIDDEN=""`, disarming the trap that is the only other thing holding a copy — and then
# cleanup's `rm -rf "$TMP"` would delete the file this case moved out of the way. The blast
# radius is build products, not vendor/, so this is recoverable with `swift build`; it is
# still not a thing to leave to luck in the one case that deliberately breaks the tree.
mv "$HIDDEN" "$SHADER" && HIDDEN=""
# Same rule as `report`: a dead harness is environmental. Checked after the restore above, so
# exiting here cannot leave the shader hidden.
if [[ "$falsify_out" == "CRASH" ]]; then
  echo "✗ the harness died running the falsification case — environmental, not a verdict" >&2
  [[ -s "$TMP/harness.err" ]] && sed 's/^/    /' "$TMP/harness.err" >&2
  exit 2
fi
falsify_live="${falsify_out#LIVE=}"; falsify_live="${falsify_live%% *}"
if [[ "$falsify_live" == "coretext" && "$falsify_out" == *"THREW="* && "$falsify_out" != *"THREW=none"* ]]; then
  say "  ok  shader hidden -> falls back to coretext AND throws (gate is discriminating)"
else
  echo "✗ FAIL: with Shaders.metal hidden, Metal still came up: $falsify_out" >&2
  echo "  This gate is BLIND: its passing cases are not caused by the shipped shader." >&2
  echo "  Most likely a stale default.metallib or a cached library is satisfying" >&2
  echo "  makeLibrary() (MetalTerminalRenderer.swift:2746). Do not trust case 1 until" >&2
  echo "  this case fails as designed." >&2
  failures=$((failures + 1))
fi

echo
if [[ "$failures" -eq 0 ]]; then
  # Counts only what THIS script ran. The pure mapping check is a sibling script with its own
  # exit code (check-renderer-config.sh) — claiming it here would be this gate reporting a
  # case it never executed, which is the same species of lie as a config that says `metal`
  # over a Core Text surface.
  echo "all metal-renderer cases passed (2 static + 3 behavioural + 1 falsification)"
  exit 0
fi
echo "$failures metal-renderer case(s) FAILED" >&2
exit 1
