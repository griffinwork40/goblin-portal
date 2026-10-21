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
#   T11 program title set while running → shown
#   T12 program title dropped after the command ends (no precmd title follows)
#   T13 precmd title after a command ends → suppressed
#   T14 title with no shell integration (never running) → suppressed
#   FALSIFY  two sed mutants on COPIES, each must fail ITS declared case:
#            m1 "~" sentinel → "HOME"            (must fail T2)
#            m2 commandEnded keeps the title      (must fail T12)
#            a mutant whose pattern no longer applies exits 2 (environmental)

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

POLICY_TO_USE="$POLICY_SRC"

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

// ── T11-T14: the explicit-title TRANSITIONS (TabTitleTracker) ──────────────
func titled(_ t: TabTitleTracker) -> String {
    TabTitlePolicy.title(foreground: .command(name: "vim"), cwdURL: proj, homeURL: home,
                         explicitTitle: t.explicitTitle, explicitKind: t.explicitKind,
                         tmuxTitle: nil)
}
var tr = TabTitleTracker()
tr.commandStarted(); tr.titleSet("vim: main.swift", running: true)
check("T11-program-title-while-running", titled(tr), "vim: main.swift")
tr.commandEnded()
check("T12-program-title-dropped-at-end", titled(tr), "vim \u{2014} goblin-portal")
tr.titleSet("alice@mac: ~/Projects/goblin-portal", running: false)
check("T13-precmd-title-suppressed", titled(tr), "vim \u{2014} goblin-portal")
var noInt = TabTitleTracker()
noInt.titleSet("alice@mac: ~", running: false)
check("T14-no-integration-suppressed", titled(noInt), "vim \u{2014} goblin-portal")

// ── summary ───────────────────────────────────────────────────────────────
print("\n\(passed) passed, \(failed) failed")
if failed > 0 { exit(1) }
SWIFT_EOF

# ── compile + run one policy source; prints harness output, returns its status ──
# ForegroundProcess.swift is Foundation+Darwin only — safe for standalone compile.
# TabTitlePolicy.swift depends on ForegroundKind from ForegroundProcess.swift.
run_policy() {  # $1 = policy source, $2 = output log
    local bin="$TMPDIR_BASE/check-tab-title-$RANDOM"
    if ! swiftc -O -module-name GoblinPortal "$1" "$FOREGROUND_SRC" "$HARNESS" \
        -o "$bin" 2>"$TMPDIR_BASE/compile.log"; then
        echo "COMPILE ERROR:" >&2; cat "$TMPDIR_BASE/compile.log" >&2
        return 2
    fi
    # `|| st=$?` rather than toggling set -e here: re-enabling errexit inside the
    # function made its own nonzero `return` abort the caller (found by tracing).
    local st=0; "$bin" >"$2" 2>&1 || st=$?
    return $st
}

if [[ $FALSIFY -eq 0 ]]; then
    echo "==> check-tab-title.sh (TabTitlePolicy truth table + TabTitleTracker transitions)"
    STATUS=0; run_policy "$POLICY_TO_USE" "$TMPDIR_BASE/out.log" || STATUS=$?
    cat "$TMPDIR_BASE/out.log"
    exit $STATUS
fi

# ── falsification: each mutant must fail ITS declared case, nothing else counts ──
# m1 targets the home sentinel; m2 deletes BOTH resets in commandEnded() that drop a
# finished program's title (the stuck-title bug found in review).
caught=0; ran=0
falsify() {  # $1 name, $2 declared case, $3 sed expression
    local mut="$TMPDIR_BASE/TabTitlePolicy_$1.swift" out="$TMPDIR_BASE/$1.log"
    sed "$3" "$POLICY_SRC" > "$mut"
    if cmp -s "$mut" "$POLICY_SRC"; then
        echo "==> $1: pattern no longer applies to the shipped policy (environmental)" >&2
        exit 2
    fi
    local st=0; run_policy "$mut" "$out" || st=$?
    ran=$((ran+1))
    if [[ $st -eq 2 ]]; then echo "==> $1: mutant did not compile (environmental)" >&2; exit 2; fi
    if [[ $st -eq 1 ]] && grep -q "^FAIL  $2" "$out"; then
        echo "==> $1: CAUGHT by $2"; caught=$((caught+1))
    elif [[ $st -eq 1 ]]; then
        echo "==> $1: WRONG-CASE (exit 1, but $2 did not fail) — counts as missed" >&2
    else
        echo "==> $1: MISSED (gate stayed green)" >&2
    fi
}
falsify m1-home-sentinel T2- 's/return "~"/return "HOME"/'
falsify m2-keep-program-title T12- '/^        explicitTitle = ""$/d; /^        explicitKind = .none$/d'
[[ $ran -eq 0 ]] && { echo "==> no mutant ran" >&2; exit 2; }
if [[ $caught -eq $ran ]]; then echo "==> FALSIFY PASSED: $caught/$ran mutants caught by their declared case"; exit 0; fi
echo "==> FALSIFY FAILED: $caught/$ran caught" >&2
exit 1
