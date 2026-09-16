#!/usr/bin/env bash
#
# check-git-status.sh — headless truth table for the git sidebar's data layer.
#
# WHAT IS UNDER TEST. `Sources/GoblinPortal/GitStatus.swift` (the porcelain-v2 grammar) and
# `Sources/GoblinPortal/GitStatusReader.swift` (repo discovery + the spawn). Both are pure
# Foundation with no AppKit, no SwiftTerm and no @MainActor precisely so this script can
# compile them directly with swiftc, the same trick check-cwd-follow.sh plays on
# ShellDirectory.swift. Nothing here launches Goblin Portal, steals focus, or needs a window
# server.
#
# THIS SCRIPT IS TWO FILES. The shell half builds the fixtures; the assertions live in
# `Scripts/check-git-status-harness.swift`, which this script copies to `main.swift` and
# compiles. That is the only structural departure from the other check scripts, and it is
# forced rather than chosen: inline, the two halves were 358 lines, over the ceiling
# check-file-size.sh enforces. The harness file's own header argues the split.
#
# WHY THIS EXISTS. The repo has no test target and no CI (AFK.md, "Checks"), so a
# feature's gate script IS its evidence. A status parser is the archetype of code that
# looks right and is wrong: the `-z` rename record silently occupies TWO NUL-delimited
# tokens, unmerged records have a different field count than ordinary ones, and
# `# branch.ab` is absent rather than zero on a branch with no upstream. None of those
# three is visible in a diff review, and all three are invisible in casual use — a repo
# with no renames, no conflicts and an upstream exercises none of them.
#
# FIXTURES ARE REAL. Every case below runs against a real `git init` with real commits,
# a real `git mv`, a real merge conflict from two genuinely diverging branches, a real
# bare remote, a real detached HEAD and a real `git worktree add`. Hand-typed porcelain
# strings were considered and refused: they encode only the author's assumptions about
# the format, which is exactly what a looks-right-is-wrong bug hides inside. Same rule
# as check-cwd-follow.sh:156-158 — executed, not string-matched.
#
# EXIT CODES, deliberately three-valued, copying check-reflow.sh: 0 = every case passed;
# 1 = a real assertion failed (the implementation is wrong); 2 = anything environmental
# — no swiftc, no git, a git too old for --porcelain=v2, a fixture that would not build,
# a harness that would not compile. A broken environment must never read as a green gate.
#
# WHAT THIS CANNOT TEST, stated so that "all green" is not misread as "fully verified".
# The gate covers discovery, the spawn and the grammar. It does NOT cover: the poller's
# cadence, the FSEvents coalescing window, badge glyph choice, colour legibility against
# the selection pill, or any of the AppKit wiring in GitStatus+Presentation.swift and
# FileTreeViewController+Git.swift — those import AppKit and cannot be compiled alone.
# They are daily-drive-verified only, the same category as `symbolName(for:)` today.
#
# ISOLATION. Everything happens under a mktemp -d removed by a trap: every repository,
# every remote and every worktree. No UserDefaults domain is touched, and no repository
# outside that directory is read or written — in particular this script never runs git
# against Goblin Portal's own checkout.
#
set -euo pipefail

# Absolute, and captured before anything cd's: the fixture builder below moves into each
# temp repository it creates, so a relative `dirname "$0"` would no longer resolve by the
# time the harness needs to be compiled.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# Every unit under test, and the reason each one qualifies: all four import Foundation
# and nothing else, so swiftc can build them without a window server. `GitStatus.swift`
# is the grammar; `+Rollup` is what a folder inherits from its children; `+Phrasing` is
# what a row says in words. `+Phrasing` in particular is here because it MUST be — its
# string logic is deterministic and therefore gateable, and the only thing that ever kept
# it ungated was living beside an `import AppKit` it never used.
PARSER="Sources/GoblinPortal/GitStatus.swift"
ROLLUP="Sources/GoblinPortal/GitStatus+Rollup.swift"
PHRASING="Sources/GoblinPortal/GitStatus+Phrasing.swift"
READER="Sources/GoblinPortal/GitStatusReader.swift"

for unit in "$PARSER" "$ROLLUP" "$PHRASING" "$READER"; do
    [ -f "$unit" ] || { echo "ENV: $unit not found (run from app/ or app/Scripts/)"; exit 2; }
done
command -v swiftc >/dev/null 2>&1 || { echo "ENV: no swiftc on PATH"; exit 2; }
command -v git >/dev/null 2>&1 || { echo "ENV: no git on PATH"; exit 2; }
[ -x /usr/bin/git ] || { echo "ENV: /usr/bin/git missing (GitStatusReader.gitPath)"; exit 2; }

# --porcelain=v2 landed in git 2.11. Older git exits non-zero on the flag, which the
# reader correctly reports as nil — indistinguishable from a real parse failure here, so
# it is an environment refusal rather than a red case.
GIT_V="$(git --version | awk '{print $3}')"
GIT_MAJOR="${GIT_V%%.*}"
GIT_REST="${GIT_V#*.}"
GIT_MINOR="${GIT_REST%%.*}"
if [ "$GIT_MAJOR" -lt 2 ] || { [ "$GIT_MAJOR" -eq 2 ] && [ "$GIT_MINOR" -lt 11 ]; }; then
    echo "ENV: git $GIT_V is too old for --porcelain=v2 (need >= 2.11)"; exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Fixtures are built with git's own commands and never with hand-written porcelain. Any
# failure here is environmental, not a red case, so the whole block is guarded.
build_fixtures() {
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    export GIT_AUTHOR_NAME=gate GIT_AUTHOR_EMAIL=gate@umber
    export GIT_COMMITTER_NAME=gate GIT_COMMITTER_EMAIL=gate@umber

    # A filename carrying every character that breaks naive handling: a space, a single
    # quote, a dollar sign and a backtick. Plus a separate one with non-ASCII UTF-8, which
    # is what `-z` exists to keep unquoted regardless of the user's core.quotePath.
    WEIRD='sp ace'"'"'s $weird`one.txt'
    EMOJI='café-😀.txt'

    # --- plain: the control case and most edges, in one repo ---
    git init -q "$WORK/plain"
    cd "$WORK/plain"
    printf 'keep\n' > control-keep.txt
    printf 'mod\n' > control-mod.txt
    printf 'del\n' > control-del.txt
    printf 'src\n' > rename-src.txt
    printf 'edited\n' > readd-src.txt
    printf 'weird\n' > "$WEIRD"
    printf 'emoji\n' > "$EMOJI"
    mkdir -p nested/deep
    printf 'buried\n' > nested/deep/buried.txt
    mkdir -p doomed
    printf 'doomed\n' > doomed/only-child.txt
    git add -A && git commit -qm base

    printf 'CHANGED\n' >> control-mod.txt          # .M  worktree-modified
    rm control-del.txt                             # .D  worktree-deleted
    printf 'new\n' > control-new.txt               # ?   untracked
    printf 'staged\n' > staged-add.txt
    git add staged-add.txt                         # A.  index-added
    git mv rename-src.txt rename-dst.txt           # 2   R. rename, TWO -z tokens
    # RM — renamed in the index, then edited again in the worktree. Still a "2" record,
    # so it carries an origin, but ordinaryEntry collapses XY to the worktree side and
    # the status comes out .modified. The one case that proves "only renames carry an
    # origin" is true of RECORDS and false of STATUSES.
    git mv readd-src.txt readd-dst.txt
    printf 'AGAIN\n' >> readd-dst.txt              # 2   RM  rename + worktree edit
    printf 'CHANGED\n' >> "$WEIRD"
    printf 'CHANGED\n' >> "$EMOJI"
    printf 'CHANGED\n' >> nested/deep/buried.txt   # rollup source
    rm doomed/only-child.txt                       # deleted-does-not-roll-up source

    # --- conflicted: a real merge conflict from two real diverging commits ---
    git init -q "$WORK/conflicted"
    cd "$WORK/conflicted"
    printf 'base\n' > c.txt && git add -A && git commit -qm base
    MAIN="$(git rev-parse --abbrev-ref HEAD)"
    git checkout -q -b other
    printf 'other\n' > c.txt && git commit -qam other
    git checkout -q "$MAIN"
    printf 'mine\n' > c.txt && git commit -qam mine
    git merge other >/dev/null 2>&1 || true        # expected to conflict
    [ -f .git/MERGE_HEAD ] || { echo "ENV: fixture did not reach a conflict"; return 1; }

    # --- upstream: a real bare remote, so `# branch.ab` is actually emitted ---
    git init -q --bare "$WORK/remote.git"
    git init -q "$WORK/upstream"
    cd "$WORK/upstream"
    printf 'a\n' > a.txt && git add -A && git commit -qm one
    git remote add origin "$WORK/remote.git"
    git push -q -u origin HEAD
    printf 'b\n' > b.txt && git add -A && git commit -qm two
    printf 'c\n' > c.txt && git add -A && git commit -qm three   # now 2 ahead, 0 behind

    # --- pruned: an upstream that is CONFIGURED but whose commit is not present ---
    # What `git fetch --prune` leaves behind once the remote branch is deleted: the
    # branch.<name>.remote/.merge config survives, the remote-tracking ref does not. git
    # then emits `# branch.upstream` and omits `# branch.ab`, so a caller reading
    # `ahead == nil` as "no upstream" is wrong about a branch that has one. Pushed under
    # its own name rather than HEAD's so the delete never touches the bare repo's HEAD.
    git init -q --bare "$WORK/remote-gone.git"
    git init -q "$WORK/pruned"
    cd "$WORK/pruned"
    printf 'p\n' > p.txt && git add -A && git commit -qm one
    git remote add origin "$WORK/remote-gone.git"
    git push -q origin HEAD:refs/heads/keepme
    git push -q -u origin HEAD:refs/heads/gate-pruned
    git push -q origin --delete gate-pruned
    git fetch -q --prune origin
    git config --get branch."$(git rev-parse --abbrev-ref HEAD)".merge >/dev/null \
        || { echo "ENV: pruned fixture lost its upstream config"; return 1; }

    # --- detached: HEAD pointing at a commit, not a branch ---
    git init -q "$WORK/detached"
    cd "$WORK/detached"
    printf 'd\n' > d.txt && git add -A && git commit -qm one
    git checkout -q --detach HEAD

    # --- linked worktree: where `.git` is a FILE, not a directory ---
    cd "$WORK/plain"
    git worktree add -q -b gate-worktree "$WORK/linked" >/dev/null 2>&1
    [ -e "$WORK/linked/.git" ] || { echo "ENV: worktree fixture missing"; return 1; }
    [ -d "$WORK/linked/.git" ] && { echo "ENV: worktree .git is a dir — git changed"; return 1; }

    # --- outer + inner-wt: a repository INSIDE another repository's working tree ---
    # Its own fixture rather than a worktree under `plain`, because `plain`'s dirty state is
    # asserted line by line and committing a .gitignore into it would move those answers.
    # This is Goblin Portal's own layout: `.afk-worktrees/*` are real repositories under the main
    # checkout, gitignored there, so the outer repo reports nothing about their contents. It
    # is the shape that makes a CONTAINMENT test the wrong way to cache a discovered
    # repository — the inner root is inside the outer one, so "still inside the repo I knew"
    # stays true after the answer has changed.
    git init -q "$WORK/outer"
    cd "$WORK/outer"
    printf 'o\n' > o.txt
    printf 'inner-wt/\n' > .gitignore
    git add -A && git commit -qm base
    git worktree add -q -b gate-nested "$WORK/outer/inner-wt" >/dev/null 2>&1
    [ -e "$WORK/outer/inner-wt/.git" ] || { echo "ENV: nested worktree fixture missing"; return 1; }
    # A change only the INNER repo can see, so "the outer repo has nothing to say about it"
    # is asserted against a file that is genuinely dirty rather than against an empty tree.
    printf 'DIRTY\n' >> "$WORK/outer/inner-wt/o.txt"

    # --- notrepo: a plain directory, to prove discovery declines ---
    mkdir -p "$WORK/notrepo/sub"
    return 0
}

if ! build_fixtures >"$WORK/fixtures.log" 2>&1; then
    echo "ENV: could not build the git fixtures"
    tail -5 "$WORK/fixtures.log" || true
    exit 2
fi
cd "$ROOT"

# The harness is a real file, not a heredoc — see its own header for why, and see
# check-file-size.sh for the ceiling that forced the split. Copied to `main.swift`
# because Swift allows top-level statements only in a file with that exact name, and
# this harness needs top-level code to drive real subprocesses.
HARNESS="Scripts/check-git-status-harness.swift"
[ -f "$HARNESS" ] || { echo "ENV: $HARNESS not found (run from app/ or app/Scripts/)"; exit 2; }
cp "$HARNESS" "$WORK/main.swift"

if ! swiftc -O "$PARSER" "$ROLLUP" "$PHRASING" "$READER" "$WORK/main.swift" \
    -o "$WORK/run" 2>"$WORK/build.log"; then
    echo "ENV: the harness would not compile against the four Foundation-only units"
    grep -E "error:" "$WORK/build.log" | head -10 || true
    exit 2
fi

# Every repository the harness touches is inside $WORK, so the isolation claim in this
# file's header is enforced by the fixture paths rather than asserted in prose.
GIT_GATE_WORK="$WORK" "$WORK/run"
