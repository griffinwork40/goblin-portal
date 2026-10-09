#!/bin/bash
#
# check-terminal-actions.sh — gate for the terminal-action guard (lane F).
#
# WHAT IS UNDER TEST. TerminalActionGuard, TerminalInputPolicy, and the four shipped
# entry points that send text into the focused shell:
#   · Insert Path       SpaceViewController.fileTree(_:didRequestPathInsert:)
#   · cd Here           SpaceViewController.fileTree(_:didRequestChangeDirectory:)
#   · ⌘⇧C              AppDelegate.sendPathToTerminal(_:)
#   · ⌘⇧R              AppDelegate.runInTerminal(_:)
# Menu validation is tested through AppDelegate.validateMenuItem(_:).
#
# WHY THIS GATE EXISTS. Without a guard, ⌘⇧R sends `python3 '<path>'` as a REPL
# prompt when agent-afk or ssh is in front; cd Here runs cd on the remote machine.
# TerminalActionGuard centralises the decision in one struct whose production seams
# (foregroundReader, beepSink) are injectable for testing.
#
# CASES (harness):
#   T1.  TerminalInputPolicy truth table — all seven inputs.
#   A6.  Insert Path (fileTree:didRequestPathInsert:): .knownShell → quoted path+space sent.
#   A7.  Insert Path: .otherMultiplexer → no bytes, one beep.
#   A8.  cd Here (fileTree:didRequestChangeDirectory:): .tmuxClient → cd command sent.
#   A9.  cd Here: .command → no bytes, one beep.
#   A1.  sendPathToTerminal: .shell → exact quoted path+space sent, no beep.
#   A2.  sendPathToTerminal: .command → no bytes, one beep.
#   A3.  sendPathToTerminal: nil → no bytes, one beep (fail-closed).
#   A4.  runInTerminal (.py): .shell → exact "python3 '<path>'\n".
#   A5.  runInTerminal: .remote → no bytes, one beep.
#   V1.  validateMenuItem: enabled for shell/knownShell/tmuxClient (3×2 items),
#        disabled for command/remote/otherMultiplexer/nil (4×2 items).
#   M1.  Safe-at-validation, unsafe-at-execution: validateMenuItem returns true for
#        .shell; foreground switches to .command at send time → no bytes, one beep.
#
# SEAMS. Each case replaces TerminalActionGuard.production.foregroundReader and
# .beepSink before calling the SHIPPED entry point. The shipped guard line in each
# method is what the falsification mutants delete; the harness must then catch that.
#
# FALSIFICATION (--falsify flag). Four mutants, each applied to a COPY of the
# shipped source in a temp directory; the real source is never touched:
#   F1.  Delete guard line in fileTree(_:didRequestChangeDirectory:) only.
#         → A9 must exit 1 (cd Here bypasses the guard for .command).
#   F2.  Delete guard line in AppDelegate.sendPathToTerminal only.
#         → A2 must exit 1 (sendPathToTerminal bypasses the guard for .command).
#   F3.  Delete guard in AppDelegate.validateMenuItem for sendPathToTerminal/runInTerminal.
#         → V1 must exit 1 (validateMenuItem always returns true).
#   F4.  Invert one case of TerminalInputPolicy in ShellContext.swift
#        (.shell → refused, .command → allowed).
#         → T1 must exit 1 (truth table is wrong).
#
# COMPILE CONTRACT. Each mutant is built by copying app/Sources to a temp dir,
# applying sed, then running `swift build` against that copy with the harness linked
# in. A compile failure of a mutant is environmental (exit 2), not "caught". The gate
# runs a clean build first so incremental compilation works; mutant builds are cold.
#
# EXIT CONTRACT:
#   0 = all cases passed.
#   1 = real assertion failure.
#   2 = environmental (swiftc missing, build failed, harness compile error).
#
set -uo pipefail

QUIET="${QUIET:-0}"
say() { [[ "$QUIET" == "1" ]] || echo "$@"; }

FALSIFY=0
for arg in "$@"; do [[ "$arg" == "--falsify" ]] && FALSIFY=1; done

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
PRODUCTS="$ROOT/.build/out/Products/Debug"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"

command -v swiftc >/dev/null 2>&1 || {
  echo "error: swiftc not found — no Swift toolchain on PATH." >&2; exit 2; }

BFLAGS=(); swift build --help 2>&1 | grep -q -- '--build-system' && BFLAGS=(--build-system swiftbuild)
say "==> building GoblinPortal (harness links against its objects)"
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

HARNESS_SRC="$ROOT/Scripts/check-terminal-actions-harness.swift"
[[ -f "$HARNESS_SRC" ]] || {
  echo "error: check-terminal-actions-harness.swift not found." >&2; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ── Normal run ───────────────────────────────────────────────────────────────────────
if [[ $FALSIFY -eq 0 ]]; then
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
  out="$("$TMP/terminal-actions" 2>&1)"; status=$?
  say "$out"
  if [[ $status -eq 0 ]]; then exit 0; fi
  if [[ $status -eq 2 ]] || ! grep -qE 'ok  |FAIL ' <<<"$out"; then
    echo "error: harness exited $status without completing cases (environmental)." >&2
    exit 2
  fi
  exit 1
fi

# ── Falsification mode ───────────────────────────────────────────────────────────────
# Each mutant:
#   1. Copies app/Sources to a temp dir.
#   2. Applies a sed mutation to the relevant source file in the copy.
#   3. Runs `swift build` against the copy to produce fresh .o files.
#   4. Compiles the harness against those .o files.
#   5. Runs the harness and requires exit 1.
#
# A compile failure (exit 2) from swift build or swiftc is environmental — the mutant
# itself is broken, not the guard. A compile failure is NOT "caught"; only exit 1 counts.
#
say "==> Falsification: four mutants must each produce exit 1"
all_ok=1

VENDOR_PATH="$REPO_ROOT/vendor/SwiftTerm"
[[ -d "$VENDOR_PATH" ]] || { echo "error: vendor/SwiftTerm not found at $VENDOR_PATH." >&2; exit 2; }

run_mutant() {
  local label="$1"       # short name for output
  local src_file="$2"    # path relative to Sources/GoblinPortal/
  local mutant_script="$3"  # path to a python3 script that mutates $1 (the target file)
  local must_fail="$4"   # assertion label for diagnosability

  local mdir="$TMP/mut-$label"
  mkdir -p "$mdir"

  # Copy sources; apply mutation via a Python script (handles multi-line blocks correctly).
  cp -a "$ROOT/Sources" "$mdir/"
  cp -a "$ROOT/Resources" "$mdir/" 2>/dev/null || true
  local target_file="$mdir/Sources/GoblinPortal/$src_file"
  if ! python3 "$mutant_script" "$target_file" 2>&1; then
    say "  MUTANT $label: Python mutation failed or produced no change"
    all_ok=0; return
  fi

  # Package.swift with absolute vendor path (required — relative ../vendor breaks in /tmp).
  cat > "$mdir/Package.swift" << PKGEOF
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "GoblinPortal",
    platforms: [.macOS(.v14)],
    dependencies: [ .package(path: "$VENDOR_PATH") ],
    targets: [
        .executableTarget(name: "GoblinPortal", dependencies: ["SwiftTerm"],
            path: "Sources/GoblinPortal",
            resources: [
                .copy("../../Resources/shell-integration.zsh"),
                .copy("../../Resources/install-update.sh"),
            ]),
        .executableTarget(name: "GoblinPortalCLI", dependencies: [], path: "Sources/GoblinPortalCLI"),
    ]
)
PKGEOF

  # Build the mutated package.
  if ! swift build "${BFLAGS[@]}" --package-path "$mdir" >/dev/null 2>"$mdir/build.log"; then
    say "  MUTANT $label: swift build failed — mutant is a compile error (environmental)"
    grep -E 'error' "$mdir/build.log" | head -5 | sed 's/^/    /' >&2
    # A compile failure is environmental — do NOT count as "detected".
    all_ok=0; return
  fi

  # Locate the objects from the mutant build.
  local mobj
  mobj="$(find "$mdir/.build/out/Intermediates.noindex" -type d \
    -path '*/GoblinPortal-p.build/Objects-normal/*' 2>/dev/null | head -1)"
  if [[ -z "$mobj" ]]; then
    say "  MUTANT $label: mutant objects not found (environmental)"; all_ok=0; return
  fi

  local mproducts="$mdir/.build/out/Products/Debug"
  local swiftterm_obj="$mproducts/SwiftTerm.o"
  [[ -f "$swiftterm_obj" ]] || swiftterm_obj="$PRODUCTS/SwiftTerm.o"

  # Compile the harness against the mutant objects.
  local mbin="$mdir/terminal-actions"
  local mobjs; mobjs=$(ls "$mobj"/*.o | grep -v '/main\.o$' | tr '\n' ' ')
  if ! swiftc -o "$mbin" "$HARNESS_SRC" \
      -I "$mobj" -I "$mproducts" -I "$mproducts/include" -L "$mproducts" \
      $mobjs "$swiftterm_obj" \
      -framework AppKit 2>"$mdir/compile.log"; then
    say "  MUTANT $label: harness would not compile against mutant (environmental)"
    grep -E 'error' "$mdir/compile.log" | head -5 | sed 's/^/    /' >&2
    all_ok=0; return
  fi

  local mout ms
  mout="$("$mbin" 2>&1)"; ms=$?
  if [[ $ms -eq 1 ]]; then
    say "  MUTANT $label: exit 1 — guard breach detected (ok)"
    say "    first FAIL line: $(grep 'FAIL' <<<"$mout" | head -1)"
  elif [[ $ms -eq 2 ]]; then
    say "  MUTANT $label: exit 2 (environmental inside harness — not caught)"
    all_ok=0
  else
    say "  MUTANT $label: exit $ms — breach NOT detected (FAIL)"
    say "$mout"
    all_ok=0
  fi
}

# Write the four Python mutation scripts to $TMP so they can be invoked cleanly
# without shell-quoting issues. Each script receives the target file path as argv[1],
# applies the mutation in place, and exits 1 (with a message) if nothing changed.

cat > "$TMP/mut_f1.py" << 'PYEOF'
import re, sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()
# Delete the 3-line guard block for "cd Here":
#   guard TerminalActionGuard.production.check(host: host, action: "cd Here") else {
#       return
#   }
result = re.sub(
    r'        guard TerminalActionGuard\.production\.check\(host: host, action: "cd Here"\) else \{\n            return\n        \}\n',
    '', content)
if result == content:
    print('F1: pattern not found in source', file=sys.stderr); sys.exit(1)
with open(path, 'w') as f:
    f.write(result)
PYEOF

cat > "$TMP/mut_f2.py" << 'PYEOF'
import re, sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()
# Delete the 2-line guard block for sendPathToTerminal:
#   guard TerminalActionGuard.production.check(host: shell, action: "Send Path to Terminal")
#   else { return }
result = re.sub(
    r'        guard TerminalActionGuard\.production\.check\(host: shell, action: "Send Path to Terminal"\)\n        else \{ return \}\n',
    '', content)
if result == content:
    print('F2: pattern not found in source', file=sys.stderr); sys.exit(1)
with open(path, 'w') as f:
    f.write(result)
PYEOF

cat > "$TMP/mut_f3.py" << 'PYEOF'
import re, sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()
# Delete the validates return in validateMenuItem so it falls through to `return true`.
result = re.sub(
    r'            return TerminalActionGuard\.production\.validates\(host: shell\)\n',
    '', content)
if result == content:
    print('F3: pattern not found in source', file=sys.stderr); sys.exit(1)
with open(path, 'w') as f:
    f.write(result)
PYEOF

cat > "$TMP/mut_f4.py" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()
# Invert the allow case: .shell/.knownShell/.tmuxClient now return false.
result = content.replace(
    'case .shell, .knownShell, .tmuxClient: return true',
    'case .shell, .knownShell, .tmuxClient: return false')
if result == content:
    print('F4: pattern not found in source', file=sys.stderr); sys.exit(1)
with open(path, 'w') as f:
    f.write(result)
PYEOF

# F1: delete the guard block in fileTree(_:didRequestChangeDirectory:) only.
#     After deletion the cd command fires unconditionally; A9 (.command → no bytes) must exit 1.
say "  --- F1: no guard in cd Here ---"
run_mutant "F1-no-cd-guard" \
  "SpaceViewController+Delegates.swift" \
  "$TMP/mut_f1.py" \
  "A9"

# F2: delete the guard block in sendPathToTerminal only.
#     After deletion send fires unconditionally; A2 (.command → no bytes) must exit 1.
say "  --- F2: no guard in sendPathToTerminal ---"
run_mutant "F2-no-sendpath-guard" \
  "AppDelegate+EditorActions.swift" \
  "$TMP/mut_f2.py" \
  "A2"

# F3: delete the validates return in validateMenuItem.
#     validateMenuItem always returns true; V1 (disabled for .command) must exit 1.
say "  --- F3: no guard in validateMenuItem ---"
run_mutant "F3-no-validate-guard" \
  "AppDelegate+Validation.swift" \
  "$TMP/mut_f3.py" \
  "V1"

# F4: invert TerminalInputPolicy: .shell/.knownShell/.tmuxClient → false.
#     T1 truth table is wrong; must exit 1.
say "  --- F4: inverted TerminalInputPolicy ---"
run_mutant "F4-inverted-policy" \
  "ShellContext.swift" \
  "$TMP/mut_f4.py" \
  "T1"

if [[ $all_ok -eq 1 ]]; then
  say "==> all four falsification mutants detected — guard is non-trivially present"
  exit 0
else
  echo "error: one or more mutants were NOT detected — guard may be bypassed." >&2
  exit 1
fi
