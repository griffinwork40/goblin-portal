#!/usr/bin/env bash
#
# check-git-watch.sh — headless gate for WHEN the git sidebar re-reads.
#
# WHAT IS UNDER TEST. `Sources/GoblinPortal/GitStatusWatch.swift`: the FSEvents stream, the
# backstop timer, the rate floor and the single start/stop switch over all three. It is
# Foundation + CoreServices only, so swiftc can build it with no window server, beside the
# equally pure `GitStatus*.swift` reader that case W9 runs inside the callback.
#
# WHY THIS EXISTS. The first cut of the FSEvents work passed every existing gate and was
# wrong twice, because no gate ran it at all:
#   * the stream was closed when a window resigned key and never re-opened, so the app was
#     silently back on the 2s poll after one deactivation (case W3, mutant m1);
#   * nothing bounded the read rate, so a build in the worktree became ~3 `git status`
#     spawns a second (case W5a, mutant m2).
# check-git-status.sh covers what a read RETURNS. This covers what ASKS for one.
#
# CASES (all against real directories and a real FSEvents stream; see the harness):
#   W1 a write asks for a read          W6 the backstop works with no stream
#   W2 stop() silences everything       W7 fsmonitor cookie writes are not changes
#   W3 stop()/start() re-opens          W8 an owner released without stop() is safe
#   W4 directories while stopped, repointing, the empty set
#   W5 churn is held to the floor, and the last write still gets a read
#   W9 real `git status` in the callback does not trigger itself; index-only changes do
# plus wiring greps on the follower, and five mutants on a COPY of the shipped file, each
# counted only when ITS declared check fails.
#
# EXIT CODES: 0 = every case passed and every mutant was caught; 1 = an assertion failed or
# a mutant survived; 2 = environmental (no swiftc, no git, a compile failure, a mutant whose
# pattern no longer applies). `--no-falsify` skips the mutants.
#
# WHAT THIS CANNOT TEST. `GitStatusFollow` itself needs AppKit and a real file tree, so its
# three call sites into the watch are pinned by grep, not driven. Whether a decoration
# visibly updates faster on screen is daily-drive territory (`GOBLIN_PORTAL_DIAG=1` prints
# `[diag] git-watch:` lines for it). Network volumes are not exercised.
#
set -uo pipefail
cd "$(dirname "$0")/.."

SRC="${GATE_SRC_DIR:-Sources/GoblinPortal}"
WATCH="$SRC/GitStatusWatch.swift"
FOLLOW="$SRC/FileTreeViewController+Git.swift"
DEPS=("$SRC/GitStatus.swift" "$SRC/GitStatus+Rollup.swift" "$SRC/GitStatus+Phrasing.swift"
  "$SRC/GitStatusReader.swift")
HARNESS="Scripts/check-git-watch-harness.swift"

command -v swiftc >/dev/null 2>&1 || { echo "ENV: no swiftc on PATH"; exit 2; }
command -v git >/dev/null 2>&1 || { echo "ENV: no git on PATH"; exit 2; }
for f in "$WATCH" "$FOLLOW" "${DEPS[@]}" "$HARNESS"; do
  [ -f "$f" ] || { echo "ENV: missing $f"; exit 2; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$HARNESS" "$WORK/main.swift"

# build <watch-source> <binary> — the watch is the only file a mutant replaces.
build() {
  swiftc -Onone -o "$2" "$1" "${DEPS[@]}" "$WORK/main.swift" >"$WORK/compile.log" 2>&1
}

# ── Part A: the truth table against the shipped file ────────────────────────────────────
if ! build "$WATCH" "$WORK/gate"; then
  echo "ENV: harness did not compile"; grep -E 'error' "$WORK/compile.log" | head -10; exit 2
fi
mkdir -p "$WORK/run"
"$WORK/gate" "$WORK/run"
status=$?
[ "$status" -eq 0 ] || exit "$status"

# ── Part B: the follower's three call sites, comments stripped ──────────────────────────
echo ""
echo "==> wiring (FileTreeViewController+Git.swift)"
code="$(grep -v '^[[:space:]]*//' "$FOLLOW")"
wiring_failed=0
want() { # want <label> <fixed string that must appear>
  if grep -qF -- "$2" <<<"$code"; then echo "  ✓ $1"; else echo "  ✗ FAIL $1"; wiring_failed=1; fi
}
want "G1 start() starts the watch" "watch.start()"
want "G2 stop() stops the watch" "watch.stop()"
want "G3 pollNow() is stamped by the watch" "watch.fireNow()"
want "G4 a repository change repoints the watch" "watch.watch(directories:"
if grep -qE '\bTimer\b' <<<"$code"; then
  echo "  ✗ FAIL G5 the follower owns no Timer (two switches was the bug)"; wiring_failed=1
else
  echo "  ✓ G5 the follower owns no Timer (two switches was the bug)"
fi
[ "$wiring_failed" -eq 0 ] || exit 1

[ "${1:-}" = "--no-falsify" ] && { echo ""; echo "OK (falsification skipped)"; exit 0; }

# ── Part C: falsification on a COPY of the shipped file ─────────────────────────────────
echo ""
echo "==> falsification (5 mutants on copies; each must fail ITS declared check)"
caught=0
total=0
# mutant <id> <case> <declared check label> <sed expression> <what it breaks>
mutant() {
  local id="$1" only="$2" label="$3" expr="$4" what="$5" dir="$WORK/$1"
  total=$((total + 1))
  mkdir -p "$dir/run"
  sed "$expr" "$WATCH" >"$dir/GitStatusWatch.swift"
  if cmp -s "$WATCH" "$dir/GitStatusWatch.swift"; then
    echo "  ENV $id: pattern no longer applies ($what)"; exit 2
  fi
  if ! build "$dir/GitStatusWatch.swift" "$dir/gate"; then
    echo "  ENV $id: mutant did not compile ($what)"
    grep -E 'error' "$WORK/compile.log" | head -5; exit 2
  fi
  GATE_ONLY="$only" "$dir/gate" "$dir/run" >"$dir/out.log" 2>&1
  if grep -qF -- "✗ FAIL $label" "$dir/out.log"; then
    echo "  ✓ $id caught by $label: $what"; caught=$((caught + 1))
  elif grep -qF -- "✗ FAIL" "$dir/out.log"; then
    echo "  ✗ $id WRONG-CASE (expected $label): $what"; grep -F "✗ FAIL" "$dir/out.log"
  else
    echo "  ✗ $id SURVIVED: $what"
  fi
}

mutant m1 W3 "W3a" 's/^        openStream()$/        _ = isRunning/' \
  "start() does not re-open the stream"
mutant m2 W5 "W5a" 's/guard wait > 0 else { return fire(source) }/if wait > -1e9 { return fire(source) }/' \
  "no rate floor"
mutant m3 W5 "W5b" 's/guard trailing == nil else { return }/if minimumInterval >= 0 { return }/' \
  "no trailing read"
mutant m4 W7 "W7a" 's/!paths.allSatisfy(Self.isNoise)/true/' \
  "fsmonitor cookies count as changes"
mutant m5 W8 "W8a" 's/retain: Self.retainInfo, release: Self.releaseInfo/retain: nil, release: nil/' \
  "the stream does not retain its watch"

echo ""
echo "$caught/$total mutants caught"
[ "$total" -gt 0 ] || { echo "ENV: no mutant ran"; exit 2; }
[ "$caught" -eq "$total" ] || exit 1
echo "all checks passed"
