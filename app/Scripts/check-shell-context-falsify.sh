#!/usr/bin/env bash
#
# check-shell-context-falsify.sh — `check-shell-context.sh --falsify`: proves the gate can
# fail. Each mutant breaks ONE shipped source file in a CLONE of the app and must turn
# the cloned gate red. Split from check-shell-context.sh to keep both under 350 lines.
#
# HOW, and why this shape. Layer 2 links the app's own objects, so mutating one source
# and compiling it alone would test nothing (a sibling lane's falsify did that: every
# mutant failed to compile, was counted "skipped", and the run exited 0). Instead:
#   1. clone the WHOLE app/ dir, .build included, with APFS `cp -cR` (copy-on-write, so
#      the clone's incremental build reuses the real build's work);
#   2. symlink <clone>/vendor to the real vendor (Package.swift's `../vendor/SwiftTerm`);
#   3. apply the mutation to the clone's copy of a SHIPPED source — never to the harness
#      or its expectations — and require the file's checksum to have changed (an
#      unchanged file means the pattern went stale: environmental, exit 2);
#   4. run the clone's own check-shell-context.sh in NORMAL mode.
# Mutant exit 1 = caught. 0 = NOT caught: falsify fails (exit 1). 2 = environmental:
# falsify exits 2. So a run in which nothing executed can never exit 0.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"          # app/
VENDOR="$(cd "$ROOT/../vendor" 2>/dev/null && pwd)" || { echo "ENV: no ../vendor"; exit 2; }
FWORK="$(mktemp -d /tmp/gpctxf.XXXXXX)"
trap 'rm -rf "$FWORK"' EXIT

RESULT=0
mutant() {
    local name="$1" file="$2" old="$3" new="$4"
    local clone="$FWORK/$name"
    mkdir -p "$clone"
    cp -cR "$ROOT" "$clone/app" 2>/dev/null || cp -R "$ROOT" "$clone/app"
    ln -s "$VENDOR" "$clone/vendor"
    local target="$clone/app/Sources/GoblinPortal/$file"
    local before after
    before="$(shasum -a 256 "$target" | cut -d' ' -f1)"
    if ! python3 - "$target" "$old" "$new" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path).read()
if text.count(old) != 1: sys.exit(1)
open(path, "w").write(text.replace(old, new))
PY
    then echo "  mutant $name: pattern no longer applies (exit 2)"; RESULT=2; return; fi
    after="$(shasum -a 256 "$target" | cut -d' ' -f1)"
    if [ "$before" = "$after" ]; then
        echo "  mutant $name: file unchanged after mutation (exit 2)"; RESULT=2; return
    fi
    set +e
    "$clone/app/Scripts/check-shell-context.sh" >"$FWORK/$name.log" 2>&1
    local rc=$?
    set -e
    local red; red="$(grep -c '✗' "$FWORK/$name.log" || true)"
    echo "  mutant $name ($file): gate exit $rc, $red case(s) red"
    case "$rc" in
        1) grep '✗' "$FWORK/$name.log" | head -3 | sed 's/^/      /' ;;
        0) echo "    NOT CAUGHT"; [ "$RESULT" -eq 2 ] || RESULT=1 ;;
        *) echo "    ENVIRONMENTAL"; tail -5 "$FWORK/$name.log" | sed 's/^/      /'; RESULT=2 ;;
    esac
    rm -rf "$clone"   # each clone's .build diverges; do not keep N of them
}

echo "FALSIFY — each mutant of a CLONE of the shipped app must turn the gate red"

# 1. A stale local OSC 7 outranks the tmux branch (the original bug, in the pure rule).
mutant stale-osc7-outranks-tmux ShellContext.swift \
'            return context(tmuxDirectory, .local)' \
'            if case .local(let path)? = reported { return context(URL(fileURLWithPath: path), .local) }
            return context(tmuxDirectory, .local)'

# 2. A command in front answers with the FOREGROUND's cwd (the retired fallback).
mutant command-uses-foreground-cwd TerminalPane+DirectoryState.swift \
'            shellDirectory = ShellDirectory.workingDirectory(of: process.shellPid)' \
'            shellDirectory = ShellDirectory.workingDirectory(of: tcgetpgrp(process.childfd))'

# 3. A late tmux answer is stored without checking it is still for the live client.
mutant late-tmux-no-key-check TerminalPane+DirectoryState.swift \
'              TmuxClientKey(pid: pid, tty: tty) == key' \
'              TmuxClientKey(pid: pid, tty: tty) == key || pid != key.pid'

# 4. A remote OSC 7 is parsed as local (the host stops deciding which filesystem).
mutant remote-osc7-parsed-as-local Osc7Directory.swift \
'            if localHostnames.contains(urlHost) {' \
'            if !urlHost.isEmpty || localHostnames.contains(urlHost) {'

# The two below break things the assertions were NOT written around.
# 5. The getter stops scheduling its own refresh on a cold cache: only an external
#    refresh (the poller) would ever ask tmux. The harness never calls refresh in polls.
mutant getter-never-self-refreshes TerminalPane+DirectoryState.swift \
'            } else {
                scheduleTmuxQuery(key, state)
            }' \
'            }'
# 6. The in-flight flag is never cleared: the first tmux query is also the last.
mutant inflight-never-cleared TerminalPane+DirectoryState.swift \
'                    self.directoryState.tmuxInFlight = nil' \
'                    _ = self.directoryState.tmuxInFlight'
# 7. A nested shell answers with the OUTER shell's cwd.
mutant known-shell-reads-outer TerminalPane+DirectoryState.swift \
'            knownShellDirectory = ShellDirectory.workingDirectory(of: pid)' \
'            knownShellDirectory = ShellDirectory.workingDirectory(of: process.shellPid + 0 * pid)'

# 8. B2 regression: a stored local OSC 7 outranks the shell's live kernel cwd again.
mutant osc7-outranks-kernel-cwd ShellContext.swift \
'            if let shellDirectory { return context(shellDirectory, .local) }
            if case .local(let path)? = reported { return context(URL(fileURLWithPath: path), .local) }' \
'            if case .local(let path)? = reported { return context(URL(fileURLWithPath: path), .local) }
            if let shellDirectory { return context(shellDirectory, .local) }'

case "$RESULT" in
    0) echo "FALSIFY: every mutant was caught"; exit 0 ;;
    1) echo "FALSIFY: at least one mutant survived"; exit 1 ;;
    *) echo "FALSIFY: environmental — at least one mutant could not be judged"; exit 2 ;;
esac
