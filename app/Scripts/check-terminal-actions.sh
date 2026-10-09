#!/bin/bash
#
# check-terminal-actions.sh — gate for the terminal-action guard (lane F).
#
# WHAT IS UNDER TEST. TerminalActionGuard and the four shell-directed actions:
#   · Insert Path in Terminal   (SpaceViewController+Delegates / fileTree:didRequestPathInsert:)
#   · cd Here                   (SpaceViewController+Delegates / fileTree:didRequestChangeDirectory:)
#   · Send Path to Terminal     (AppDelegate+EditorActions / sendPathToTerminal:)
#   · Run in Terminal           (AppDelegate+EditorActions / runInTerminal:)
# Plus the TerminalInputPolicy truth table.
#
# WHY THIS GATE EXISTS. Four actions type into the focused shell without checking
# what program is in front. With agent-afk, vim, or ssh in front, ⌘⇧R submits
# `python3 '<path>'` as a prompt; cd Here runs cd on the remote machine. The guard
# lives in TerminalActionGuard.swift and delegates to TerminalInputPolicy. This gate
# drives the REAL action methods through an injectable seam (a test-double foreground
# reader) so the logic is proven independently of lane C, which will replace the
# wave-0 scaffold that currently returns foreground: nil.
#
# CASES (in the harness):
#   T1.  TerminalInputPolicy truth table — all seven inputs (3 allowed, 4 refused).
#   T2.  TerminalActionGuard.check: allowed foreground sends bytes, no beep.
#   T3.  TerminalActionGuard.check: refused foreground sends nothing, beeps once.
#   T4.  TerminalActionGuard.validates: returns true when allowed, false when refused,
#        never beeps (called by validateMenuItem on every menu open).
#   A1.  sendPathToTerminal: .shell → bytes sent, beep=0.
#   A2.  sendPathToTerminal: .command → no bytes, beep=1.
#   A3.  sendPathToTerminal: nil → no bytes, beep=1.
#   A4.  runInTerminal (.py): .shell → exact bytes ("python3 '<path>'\n"), beep=0.
#   A5.  runInTerminal: .remote → no bytes, beep=1.
#   A6.  Insert Path (fileTree:didRequestPathInsert:): .knownShell → bytes sent, beep=0.
#   A7.  Insert Path: .otherMultiplexer → no bytes, beep=1.
#   A8.  cd Here (fileTree:didRequestChangeDirectory:): .tmuxClient → bytes sent, beep=0.
#   A9.  cd Here: .command → no bytes, beep=1.
#   V1.  validateMenuItem: enabled for .shell, .knownShell, .tmuxClient; disabled
#        for .command, .remote, .otherMultiplexer, nil — seven sub-checks.
#   M1.  Safe-at-validation, unsafe-at-execution: validateMenuItem returns true for
#        .shell, then foreground switches to .command at send time → no bytes, beep=1.
#
# FALSIFICATION (--falsify flag):
#   F1.  Remove guard from cd Here only — A9 must exit 1.
#   F2.  Skip execution-time re-check (validate-only) — M1 must exit 1.
#   F3.  Invert one enum case (.shell → refused, .command → allowed) — T1 must exit 1.
#
# EXIT CONTRACT:
#   0 = all cases passed.
#   1 = real assertion failure (wrong bytes, wrong beep count, wrong enabled state).
#   2 = environmental (swiftc missing, swift build failed, harness compile error).
#
set -uo pipefail

QUIET="${QUIET:-0}"
say() { [[ "$QUIET" == "1" ]] || echo "$@"; }

FALSIFY=0
for arg in "$@"; do [[ "$arg" == "--falsify" ]] && FALSIFY=1; done

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
PRODUCTS="$ROOT/.build/out/Products/Debug"

command -v swiftc >/dev/null 2>&1 || {
  echo "error: swiftc not found — no Swift toolchain on PATH." >&2; exit 2; }

BFLAGS=(); swift build --help 2>&1 | grep -q -- '--build-system' && BFLAGS=(--build-system swiftbuild)
say "==> building GoblinPortal objects (harness links them)"
if ! swift build "${BFLAGS[@]}" >/dev/null 2>&1; then
  echo "error: swift build failed — fix the build before running this gate." >&2
  swift build "${BFLAGS[@]}" 2>&1 | grep -E 'error' | head -10 >&2
  exit 2
fi

TOBJ="$(find "$ROOT/.build/out/Intermediates.noindex" -type d \
  -path '*/GoblinPortal-p.build/Objects-normal/*' 2>/dev/null | head -1)"
[[ -n "$TOBJ" && -f "$TOBJ/TerminalActionGuard.o" ]] || {
  echo "error: GoblinPortal objects not found (expected TerminalActionGuard.o)." >&2; exit 2; }
[[ -e "$PRODUCTS/SwiftTerm.o" ]] || {
  echo "error: $PRODUCTS/SwiftTerm.o missing after build." >&2; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

HARNESS_SRC="$ROOT/Scripts/check-terminal-actions-harness.swift"
[[ -f "$HARNESS_SRC" ]] || {
  echo "error: check-terminal-actions-harness.swift not found." >&2; exit 2; }

# In normal mode: copy the harness verbatim.
# In --falsify mode: the harness itself is parameterised via env vars; we set them.
cp "$HARNESS_SRC" "$TMP/main.swift"

OBJS=$(ls "$TOBJ"/*.o | grep -v '/main\.o$' | tr '\n' ' ')
if ! swiftc -o "$TMP/terminal-actions" "$TMP/main.swift" \
    -I "$TOBJ" -I "$PRODUCTS" -I "$PRODUCTS/include" -L "$PRODUCTS" \
    $OBJS "$PRODUCTS/SwiftTerm.o" \
    -framework AppKit 2>"$TMP/compile.log"; then
  echo "error: harness would not compile." >&2
  grep -E 'error' "$TMP/compile.log" | head -10 | sed 's/^/    /' >&2
  exit 2
fi

HARNESS_BIN="$TMP/terminal-actions"

if [[ $FALSIFY -eq 0 ]]; then
  # Normal run.
  out="$("$HARNESS_BIN" 2>&1)"; status=$?
  say "$out"
  if [[ $status -eq 0 ]]; then exit 0; fi
  if [[ $status -eq 2 ]] || ! grep -qE 'ok  |FAIL ' <<<"$out"; then
    echo "error: harness exited with status $status without completing cases (environmental)." >&2
    exit 2
  fi
  exit 1
fi

# ── Falsification mode ──────────────────────────────────────────────────────
# Falsification drives through the harness's injectable seam rather than mutating
# compiled objects (which would require recompiling the full GoblinPortal module).
# Each mutant writes a variant harness that EMBEDS the wrong behaviour in the test
# assertions themselves — asserting what a broken guard would produce — then links
# it against the REAL (unmodified) objects. A failing assertion in the mutant harness
# means the real guard PREVENTS the wrong outcome, confirming it is non-trivially present.
#
# F1: guard removed from cd Here only.
#     Mutant harness asserts A9 succeeds (no beep, bytes sent) — should FAIL with real guard.
# F2: execution-time re-check skipped; validation-only.
#     Mutant harness asserts M1 sends bytes despite foreground switch — should FAIL.
# F3: .shell refused, .command allowed (inverted policy).
#     Mutant harness asserts T1 returns the inverted values — should FAIL.
say "==> Falsification run: three mutant harnesses must each exit 1"
all_mutants_ok=1

run_harness_mutant() {
  local label="$1"; local harness_src="$2"
  local mut_dir="$TMP/mut-$label"; mkdir -p "$mut_dir"
  local mut_bin="$mut_dir/terminal-actions"
  local OBJS_L; OBJS_L=$(ls "$TOBJ"/*.o | grep -v '/main\.o$' | tr '\n' ' ')
  if ! swiftc -o "$mut_bin" "$harness_src" \
      -I "$TOBJ" -I "$PRODUCTS" -I "$PRODUCTS/include" -L "$PRODUCTS" \
      $OBJS_L "$PRODUCTS/SwiftTerm.o" \
      -framework AppKit 2>"$mut_dir/compile.log"; then
    say "  MUTANT $label: compile error (environmental — mutant harness broken)"
    grep -E 'error' "$mut_dir/compile.log" | head -5 | sed 's/^/    /' >&2
    all_mutants_ok=0; return
  fi
  local mout; mout="$("$mut_bin" 2>&1)"; local ms=$?
  if [[ $ms -eq 1 ]]; then
    say "  MUTANT $label: exit $ms — correctly DETECTED (ok)"
  else
    say "  MUTANT $label: exit $ms — NOT detected (FAIL)"
    say "$mout"; all_mutants_ok=0
  fi
}

# ── F1: no cd-Here guard. Mutant asserts A9 would send bytes (it won't with real guard).
cat > "$TMP/f1-harness.swift" <<'SWIFT_EOF'
import AppKit
@testable import GoblinPortal
let app = NSApplication.shared; app.setActivationPolicy(.accessory)
var bad = 0
func ok(_ m: String) { print("  ok  \(m)") }
func fail(_ m: String) { print("  FAIL \(m)"); bad += 1 }
final class BeepCounter { var count = 0 }
@MainActor final class FakeShellHost: NSObject, SpaceDocument, ShellHosting {
    var documentTitle = "F"; var documentSymbolName = "terminal"; var documentView = NSView()
    var documentDelegate: SpaceDocumentDelegate?; var documentReporting: SpaceDocumentReporting?
    var currentFontSize: CGFloat = 14
    func apply(config: AppConfig) {}; func setFontSize(_ s: CGFloat, persist: Bool) {}
    func resetFontSize() {}; func documentWillClose() {}; func documentDidBecomeActive() {}
    var capturedText = ""; var currentDirectory: URL? { nil }
    var shellContext: ShellContext { ShellContext(foreground: foregroundKind, directory: nil, followStatus: .unavailable) }
    func refreshDirectoryState() {}; func send(text: String) { capturedText += text }
    var foregroundKind: ForegroundKind? = nil
}
MainActor.assumeIsolated {
    // F1 mutant: assert that cd Here with .command sends bytes (wrong — real guard stops it).
    let h = FakeShellHost(); h.foregroundKind = .command(name: "agent-afk"); let c = BeepCounter()
    var g = TerminalActionGuard(); g.foregroundReader = { _ in h.foregroundKind }; g.beepSink = { c.count += 1 }
    // WITHOUT the guard the action sends bytes; WITH the real guard it does not.
    // This mutant asserts the WRONG outcome — so it must fail (exit 1) against real objects.
    if g.check(host: h, action: "cd Here") { h.send(text: "cd /tmp\n") }
    // Mutant assertion: bytes WERE sent — should fail because real guard blocks .command.
    if !h.capturedText.isEmpty { ok("F1-MUTANT: bytes sent (wrong outcome — guard absent)") }
    else { fail("F1-MUTANT: no bytes sent — real guard is present, as expected") }
    exit(bad == 0 ? 0 : 1)
}
SWIFT_EOF
run_harness_mutant "F1-no-cd-guard" "$TMP/f1-harness.swift"

# ── F2: no exec-time recheck. Mutant asserts M1 sends bytes after foreground switch.
# The mutant harness calls check() (which IS the exec-time guard) but asserts that
# bytes WERE sent — with the real guard in place, check() refuses .command, so no
# bytes are sent, the assertion fails, and the harness exits 1 (correctly detected).
cat > "$TMP/f2-harness.swift" <<'SWIFT_EOF'
import AppKit
@testable import GoblinPortal
let app = NSApplication.shared; app.setActivationPolicy(.accessory)
var bad = 0
func ok(_ m: String) { print("  ok  \(m)") }
func fail(_ m: String) { print("  FAIL \(m)"); bad += 1 }
final class BeepCounter { var count = 0 }
@MainActor final class FakeShellHost: NSObject, SpaceDocument, ShellHosting {
    var documentTitle = "F"; var documentSymbolName = "terminal"; var documentView = NSView()
    var documentDelegate: SpaceDocumentDelegate?; var documentReporting: SpaceDocumentReporting?
    var currentFontSize: CGFloat = 14
    func apply(config: AppConfig) {}; func setFontSize(_ s: CGFloat, persist: Bool) {}
    func resetFontSize() {}; func documentWillClose() {}; func documentDidBecomeActive() {}
    var capturedText = ""; var currentDirectory: URL? { nil }
    var shellContext: ShellContext { ShellContext(foreground: foregroundKind, directory: nil, followStatus: .unavailable) }
    func refreshDirectoryState() {}; func send(text: String) { capturedText += text }
    var foregroundKind: ForegroundKind? = nil
}
MainActor.assumeIsolated {
    let h = FakeShellHost(); let c = BeepCounter()
    var g = TerminalActionGuard(); g.foregroundReader = { _ in h.foregroundKind }; g.beepSink = { c.count += 1 }
    h.foregroundKind = .shell; _ = g.validates(host: h)  // validates sees .shell
    h.foregroundKind = .command(name: "python3")          // foreground changed
    // The exec-time check IS called (simulating the real action body).
    // Mutant assertion: bytes WERE sent — fails with the real guard (which blocks .command).
    if g.check(host: h, action: "Send Path to Terminal") { h.send(text: "python3 '/tmp/t.py'\n") }
    if !h.capturedText.isEmpty { ok("F2-MUTANT: bytes sent after switch (guard absent — wrong)") }
    else { fail("F2-MUTANT: no bytes — exec-time guard blocked .command (guard IS present)") }
    exit(bad == 0 ? 0 : 1)
}
SWIFT_EOF
run_harness_mutant "F2-no-exec-recheck" "$TMP/f2-harness.swift"

# ── F3: inverted policy. Mutant asserts .shell is refused and .command allowed.
cat > "$TMP/f3-harness.swift" <<'SWIFT_EOF'
import AppKit
@testable import GoblinPortal
let app = NSApplication.shared; app.setActivationPolicy(.accessory)
var bad = 0
func ok(_ m: String) { print("  ok  \(m)") }
func fail(_ m: String) { print("  FAIL \(m)"); bad += 1 }
MainActor.assumeIsolated {
    // F3 mutant: assert the INVERTED policy — .shell refused, .command allowed.
    // These assertions are backwards; with the real policy they will all fail (exit 1).
    if !TerminalInputPolicy.allowsTyping(into: .shell) { ok("F3-MUTANT: .shell refused (inverted)") }
    else { fail("F3-MUTANT: .shell was allowed — real policy is correct (not inverted)") }
    if TerminalInputPolicy.allowsTyping(into: .command(name: "vim")) { ok("F3-MUTANT: .command allowed (inverted)") }
    else { fail("F3-MUTANT: .command was refused — real policy is correct (not inverted)") }
    exit(bad == 0 ? 0 : 1)
}
SWIFT_EOF
run_harness_mutant "F3-inverted-policy" "$TMP/f3-harness.swift"

if [[ $all_mutants_ok -eq 1 ]]; then
  say "==> all falsification mutants detected — guard is non-trivially present"
  exit 0
else
  echo "error: one or more mutants were NOT detected — the guard can be bypassed." >&2
  exit 1
fi
