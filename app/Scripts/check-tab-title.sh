#!/usr/bin/env bash
# check-tab-title.sh
# Headless truth table over TabTitlePolicy.swift — T5.3
#
# EXIT CODES (contract shared with every other check-*.sh):
#   0  all cases passed
#   1  at least one truth-table case failed (real policy regression)
#   2  environmental failure (swiftc not found, source file missing, compile error)
#
# FALSIFICATION.  At least one sed mutant on a COPY of the shipped policy must
# make this gate exit 1 on its declared case.  Enabled by --falsify.
#
# CASES:
#   T1  idle shell → cwd basename
#   T2  idle shell at home → "~"
#   T3  command in front → "command — cwd"
#   T4  remote (ssh) → program name "ssh"
#   T5  tmux client, no tmux title → falls back to cwd basename
#   T6  other multiplexer (screen) → "screen"
#   T7  explicit .program title is honoured
#   T8  explicit .shellPrompt title is suppressed → derived title used
#   T9  long name truncated to ≤ 28 chars + ellipsis
#   T10 known shell (nested bash) → nested shell's cwd basename
#   FALSIFY  sed-mutant copy: changing "~" sentinel → gate must fail T2

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../Sources/GoblinPortal"
POLICY_SRC="$SRC/TabTitlePolicy.swift"
FOREGROUND_SRC="$SRC/ForegroundProcess.swift"

# ── environment guards ────────────────────────────────────────────────────────
if ! command -v swiftc &>/dev/null; then
    echo "SKIP: swiftc not found" >&2; exit 2
fi
if [[ ! -f "$POLICY_SRC" ]]; then
    echo "SKIP: TabTitlePolicy.swift not found at $POLICY_SRC" >&2; exit 2
fi
if [[ ! -f "$FOREGROUND_SRC" ]]; then
    echo "SKIP: ForegroundProcess.swift not found at $FOREGROUND_SRC" >&2; exit 2
fi

# ── optional falsify mode ─────────────────────────────────────────────────────
FALSIFY=0
[[ "${1:-}" == "--falsify" ]] && FALSIFY=1

# ── build directory ───────────────────────────────────────────────────────────
TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# When falsifying, sed-mutate a COPY so the shipped source is never touched.
if [[ $FALSIFY -eq 1 ]]; then
    MUTANT_POLICY="$TMPDIR_BASE/TabTitlePolicy_mutant.swift"
    # Mutant: change the home-sentinel "~" to "HOME" — T2 must now fail
    sed 's/return "~"/return "HOME"/' "$POLICY_SRC" > "$MUTANT_POLICY"
    POLICY_TO_USE="$MUTANT_POLICY"
    echo "==> FALSIFY mode: mutated copy at $MUTANT_POLICY"
else
    POLICY_TO_USE="$POLICY_SRC"
fi

# ── harness source ────────────────────────────────────────────────────────────
HARNESS="$TMPDIR_BASE/main.swift"
cat > "$HARNESS" << 'SWIFT_EOF'
import Foundation

// ── ForegroundKind stubs (re-declared for standalone compile) ─────────────
// ForegroundProcess.swift defines ForegroundKind; we compile it alongside,
// so no stub needed — it's included in the compile command below.

// ── helpers ───────────────────────────────────────────────────────────────
var passed = 0
var failed = 0

func check(_ label: String, _ got: String, _ want: String) {
    if got == want {
        print("  ok  \(label): \"\(got)\"")
        passed += 1
    } else {
        print("FAIL  \(label): got \"\(got)\" want \"\(want)\"")
        failed += 1
    }
}

let home = URL(fileURLWithPath: "/Users/alice", isDirectory: true)
let proj = URL(fileURLWithPath: "/Users/alice/Projects/goblin-portal", isDirectory: true)
let deep = URL(fileURLWithPath: "/usr/local/share/something-really-long-directory-name-here", isDirectory: true)

// ── T1: idle shell → cwd basename ─────────────────────────────────────────
check("T1-idle-shell-cwd",
    TabTitlePolicy.title(foreground: .shell, cwdURL: proj, homeURL: home,
                         explicitTitle: "", explicitKind: .none, tmuxTitle: nil),
    "goblin-portal")

// ── T2: idle shell at home → "~" ──────────────────────────────────────────
check("T2-idle-shell-home",
    TabTitlePolicy.title(foreground: .shell, cwdURL: home, homeURL: home,
                         explicitTitle: "", explicitKind: .none, tmuxTitle: nil),
    "~")

// ── T3: command in front → "command — cwd" ────────────────────────────────
check("T3-command-cwd",
    TabTitlePolicy.title(foreground: .command(name: "afk"), cwdURL: proj, homeURL: home,
                         explicitTitle: "", explicitKind: .none, tmuxTitle: nil),
    "afk \u{2014} goblin-portal")

// ── T4: remote (ssh) → program name ───────────────────────────────────────
check("T4-remote-ssh",
    TabTitlePolicy.title(foreground: .remote(name: "ssh"), cwdURL: nil, homeURL: home,
                         explicitTitle: "", explicitKind: .none, tmuxTitle: nil),
    "ssh")

// ── T5: tmux client, no tmux title → cwd basename ─────────────────────────
check("T5-tmux-no-title",
    TabTitlePolicy.title(foreground: .tmuxClient(pid: 123, tty: "/dev/ttys001"),
                         cwdURL: proj, homeURL: home,
                         explicitTitle: "", explicitKind: .none, tmuxTitle: nil),
    "goblin-portal")

// ── T6: other multiplexer → program name ──────────────────────────────────
check("T6-multiplexer-screen",
    TabTitlePolicy.title(foreground: .otherMultiplexer(name: "screen"), cwdURL: nil,
                         homeURL: home, explicitTitle: "", explicitKind: .none, tmuxTitle: nil),
    "screen")

// ── T7: explicit .program title is honoured ───────────────────────────────
check("T7-explicit-program",
    TabTitlePolicy.title(foreground: .command(name: "vim"), cwdURL: proj, homeURL: home,
                         explicitTitle: "vim: main.swift", explicitKind: .program, tmuxTitle: nil),
    "vim: main.swift")

// ── T8: explicit .shellPrompt title suppressed → derived title used ────────
check("T8-shell-prompt-suppressed",
    TabTitlePolicy.title(foreground: .shell, cwdURL: proj, homeURL: home,
                         explicitTitle: "alice@host: ~/Projects/goblin-portal",
                         explicitKind: .shellPrompt, tmuxTitle: nil),
    "goblin-portal")

// ── T9: long name truncated ────────────────────────────────────────────────
let result9 = TabTitlePolicy.title(foreground: .shell, cwdURL: deep, homeURL: home,
                                    explicitTitle: "", explicitKind: .none, tmuxTitle: nil)
let ok9 = result9.count <= 28 && result9.hasSuffix("\u{2026}")
if ok9 {
    print("  ok  T9-truncation: \"\(result9)\" (len=\(result9.count))")
    passed += 1
} else {
    print("FAIL  T9-truncation: got \"\(result9)\" (len=\(result9.count)), want ≤28 chars with ellipsis")
    failed += 1
}

// ── T10: nested known shell → cwd basename ────────────────────────────────
check("T10-known-shell-cwd",
    TabTitlePolicy.title(foreground: .knownShell(pid: 456, name: "bash"), cwdURL: proj,
                         homeURL: home, explicitTitle: "", explicitKind: .none, tmuxTitle: nil),
    "goblin-portal")

// ── summary ───────────────────────────────────────────────────────────────
print("\n\(passed) passed, \(failed) failed")
if failed > 0 { exit(1) }
SWIFT_EOF

# ── compile ───────────────────────────────────────────────────────────────────
BINARY="$TMPDIR_BASE/check-tab-title"

# ForegroundProcess.swift is Foundation+Darwin only — safe for standalone compile.
# TabTitlePolicy.swift depends on ForegroundKind from ForegroundProcess.swift.
if ! swiftc -O -module-name GoblinPortal \
    "$POLICY_TO_USE" \
    "$FOREGROUND_SRC" \
    "$HARNESS" \
    -o "$BINARY" 2>"$TMPDIR_BASE/compile.log"; then
    echo "COMPILE ERROR:" >&2
    cat "$TMPDIR_BASE/compile.log" >&2
    exit 2
fi

# ── run ───────────────────────────────────────────────────────────────────────
echo "==> check-tab-title.sh (TabTitlePolicy truth table)"
# Disable set -e for this one invocation so a failing harness (exit 1) does not
# abort the script before we can inspect STATUS — that would break the FALSIFY
# path, which expects exit 1 from the mutant and must report FALSIFY PASSED.
set +e
"$BINARY"
STATUS=$?
set -e

if [[ $FALSIFY -eq 1 ]]; then
    if [[ $STATUS -eq 1 ]]; then
        echo "==> FALSIFY PASSED: mutant correctly failed (exit 1)"
        exit 0
    else
        echo "==> FALSIFY FAILED: mutant should have exited 1 but got $STATUS" >&2
        exit 1
    fi
fi

exit $STATUS
