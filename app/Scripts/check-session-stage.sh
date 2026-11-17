#!/bin/bash
# check-session-stage.sh — headless gate for T5.5 "Stage Session Changes" (#298).
#
# WHAT IS UNDER TEST. `SessionStagePolicy.pathsToStage`, the pure function that decides
# which of the session's files one `git add` may touch, `GitOperations.stage(paths:in:)`,
# the multi-path add it feeds, and `SessionStageOperation.stageFromFreshRead`, the shipped
# read-decide-add sequence the action runs in the background. The index has no undo, so this is the part of T5.5 that can
# damage a user's work, and it gets the strongest check the repo has: a truth table, real
# repositories, and mutants.
#
# WHY A SIBLING OF check-session-highlight.sh rather than an extension of it. That gate
# compiles ONE file (the accumulation store) and stays that way; this one needs the
# porcelain model, the reader and the git writer, and its real-repository half would push
# a combined script past the 350-line ceiling. The assertions live in
# `check-session-stage-harness.swift` (copied to `main.swift`), the same split
# check-git-status.sh makes.
#
# Compiled units, all Foundation-only: SessionStageOperation.swift, SessionStagePolicy.swift,
# SessionHighlightPolicy.swift (the real store feeds the real-repo cases), GitStatus.swift,
# GitStatus+Rollup.swift, GitStatus+Phrasing.swift, GitStatusReader.swift, GitOperations.swift.
#
# T cases: one truth-table row per policy rule (candidates, partial-staging skip incl. an
# untracked file over a staged deletion, conflict skip, repository identity, rename
# original, empty results). G cases: a real repository under mktemp, real `git`, the
# real store and policy, staged with the real writer — a deletion is staged, an untracked file is added, a partially staged file's index entry
# is byte-identical before and after, an unstaged rename ends fully staged, and a file
# named like a glob stages only itself, and an empty list spawns nothing (G10 stages it
# against a repository whose root does not exist, so a spawned git would fail). G11–G12,
# the stale-snapshot race: a snapshot is taken while a session file is plainly unstaged,
# one of its hunks is staged AFTER that, and the shipped read-decide-add must leave the
# file's index entry and staged blob byte-identical while staging another session file.
# G13: the shipped read-decide-add against a repository whose folder does not exist must
# return failure (the panel shows it) and leave every index unchanged. G14: a session file
# the user took out of the index with `git rm --cached` (porcelain emits `1 D.` and then `?`
# for the same path) must stay out of it while another session file is staged.
#
# FALSIFICATION (AFK.md Conventions): each mutant edits a COPY of shipped source and is
# counted only when ITS declared case fails. A pattern that no longer applies, a mutant
# that does not compile, or a mutant run that hits an environmental error exits 2.
#
# WHAT THIS CANNOT TEST: the menu, palette and validation wiring and the row marker's
# on-screen rendering import AppKit; see AFK.md Known Risks.
#
# exit 0 = all pass; 1 = assertion failed or a mutant was missed; 2 = environmental.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="${GATE_SRC_DIR:-$SCRIPT_DIR/../Sources/GoblinPortal}"
HARNESS="$SCRIPT_DIR/check-session-stage-harness.swift"
UNITS="SessionStageOperation.swift SessionStagePolicy.swift SessionHighlightPolicy.swift GitStatus.swift GitStatus+Rollup.swift GitStatus+Phrasing.swift GitStatusReader.swift GitOperations.swift"

for u in $UNITS; do
    [ -f "$SRC_DIR/$u" ] || { echo "ENV: $u not found in $SRC_DIR" >&2; exit 2; }
done
[ -f "$HARNESS" ] || { echo "ENV: $HARNESS not found" >&2; exit 2; }
command -v swiftc >/dev/null 2>&1 || { echo "ENV: no swiftc on PATH" >&2; exit 2; }
[ -x /usr/bin/git ] || { echo "ENV: /usr/bin/git missing (GitStatusReader.gitPath)" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Fixture identity and isolation from the user's git config, as check-git-status.sh does.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=gate GIT_AUTHOR_EMAIL=gate@goblin-portal
export GIT_COMMITTER_NAME=gate GIT_COMMITTER_EMAIL=gate@goblin-portal

# build DIR OUT — compile the units found in DIR with the harness into OUT.
build() {
    local dir="$1" out="$2"
    local files=()
    for u in $UNITS; do files+=("$dir/$u"); done
    mkdir -p "$out.d"
    cp "$HARNESS" "$out.d/main.swift"
    swiftc "${files[@]}" "$out.d/main.swift" -o "$out" 2>"$out.log"
}

# run BIN LOG — run a built harness in a fresh repository directory; echo its exit code.
run_harness() {
    local bin="$1" log="$2" repo
    repo="$(mktemp -d "$WORK/repo.XXXXXX")"
    local rc=0
    GIT_GATE_WORK="$repo" "$bin" >"$log" 2>&1 || rc=$?
    echo "$rc"
}

echo "compiling shipped units + harness..."
if ! build "$SRC_DIR" "$WORK/shipped"; then
    grep -E "error:" "$WORK/shipped.log" | head -10 >&2 || true
    echo "ENV: shipped harness would not compile" >&2
    exit 2
fi

rc="$(run_harness "$WORK/shipped" "$WORK/shipped.out")"
cat "$WORK/shipped.out"
case "$rc" in
    0) ;;
    1) echo "FAIL: session-stage cases" >&2; exit 1 ;;
    *) echo "ENV: harness exited $rc" >&2; exit 2 ;;
esac

# ── falsification ────────────────────────────────────────────────────────────
echo ""
echo "falsification..."
caught=0
missed=0

# run_mutant NAME FILE SED_EXPR DECLARED_CASE DESCRIPTION
run_mutant() {
    local name="$1" file="$2" expr="$3" declared="$4" desc="$5"
    local mdir="$WORK/m-$name"
    mkdir -p "$mdir"
    for u in $UNITS; do cp "$SRC_DIR/$u" "$mdir/$u"; done
    sed -i '' "$expr" "$mdir/$file"
    if cmp -s "$SRC_DIR/$file" "$mdir/$file"; then
        echo "ENV: $name pattern no longer applies to $file" >&2
        exit 2
    fi
    if ! build "$mdir" "$mdir/bin"; then
        echo "ENV: $name does not compile" >&2
        exit 2
    fi
    local mrc
    mrc="$(run_harness "$mdir/bin" "$mdir/out")"
    if [ "$mrc" -ge 2 ]; then
        echo "ENV: $name run hit an environmental error (exit $mrc)" >&2
        sed -n '1,20p' "$mdir/out" >&2
        exit 2
    fi
    if grep -q "FAIL  $declared " "$mdir/out"; then
        echo "  ok  $name ($desc) caught by $declared"
        caught=$((caught + 1))
    else
        echo "  FAIL  $name ($desc) not caught by its declared case $declared"
        missed=$((missed + 1))
    fi
}

# m1: stage partially staged entries — git add would overwrite hunk-level staging.
run_mutant m1 SessionStagePolicy.swift \
    's/if entry\.isStaged \&\& entry\.hasWorkingTreeChange { continue }/if false { continue }/' \
    T6 "partial-staging skip removed"

# m2: stage conflicted entries — git add would mark them resolved.
run_mutant m2 SessionStagePolicy.swift \
    's/if entry\.status == \.conflicted { continue }/if false { continue }/' \
    T8 "conflict skip removed"

# m3: ignore repository identity — repo A's session paths staged in repo B.
run_mutant m3 SessionStagePolicy.swift \
    's/guard let sessionRoot, let panelRoot, sessionRoot == panelRoot else { return \[] }/_ = (sessionRoot, panelRoot)/' \
    T9 "root check removed"

# m4: drop --pathspec-from-file=- — paths are never written to stdin so git
# stages nothing, and G7's glob-named file is never added.
run_mutant m4 GitOperations.swift \
    's/"--pathspec-from-file=-", "--pathspec-file-nul"/"--pathspec-file-nul"/' \
    G7 "pathspec-from-file arg dropped; paths never reach git add"

# m5: stage staged-only entries too (candidate rule widened to every entry).
run_mutant m5 SessionStagePolicy.swift \
    's/if entry\.status == \.untracked || entry\.hasWorkingTreeChange {/if true {/' \
    T5 "candidate rule widened"

# m6: decide from a snapshot the caller passed in (the panel's cached read, the pre-fix
# design) instead of reading status in the same operation — a hunk staged after that read
# is overwritten. `CallerSnapshot` exists only in the harness.
run_mutant m6 SessionStageOperation.swift \
    's/guard let fresh = GitStatusReader\.snapshot(of: repository) else/guard let fresh = CallerSnapshot.value else/' \
    G11 "decides from a caller-supplied stale snapshot"

# m7: drop the empty-list guard — an empty selection would spawn a bare `git add --`.
run_mutant m7 GitOperations.swift \
    's/guard !paths\.isEmpty else { return \.success(()) }/_ = paths.isEmpty/' \
    G10 "empty-list guard removed"

# m8: report success when the fresh status read fails — the click does nothing, silently.
run_mutant m8 SessionStageOperation.swift \
    's/return \.failure(GitOperationError(message: statusReadFailedMessage))/return .success(())/' \
    G13 "failed status read reported as success"

# m9: let the `?` record overwrite the `1 D.` record for the same path (the pre-fix parser)
# — a file the user untracked with `git rm --cached` reads as plain untracked and is re-added.
run_mutant m9 GitStatus.swift \
    's/isStaged: stagedEarlier, hasWorkingTreeChange: true/isStaged: false, hasWorkingTreeChange: true/' \
    G14 "untracked record overwrites a staged deletion"

echo ""
echo "falsification: $caught caught, $missed missed"
if [ "$caught" -eq 0 ] && [ "$missed" -eq 0 ]; then
    echo "ENV: no mutant ran" >&2
    exit 2
fi
if [ "$missed" -gt 0 ]; then
    echo "FAIL: falsification" >&2
    exit 1
fi

echo ""
echo "all checks passed"
