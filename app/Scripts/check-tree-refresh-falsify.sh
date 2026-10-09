#!/bin/bash
#
# check-tree-refresh-falsify.sh — mutation test for check-tree-refresh.sh (#158).
# Reached as `check-tree-refresh.sh --falsify`.
#
# WHY: a gate that passes is only evidence if it would FAIL on the bug it names. Each
# mutant below re-introduces one bug the async loaders exist to prevent
# (FileTreeViewController+Loading.swift, FileNode.swift `reconcile`,
# FileTreeViewController.swift `setRoot`) into a COPY of app/, and the copy's own gate
# must then exit 1.
#
# HOW: `cp -cR` (APFS clone, cheap) app/ including .build into a mktemp dir, symlink
# <tmp>/vendor to the real vendor/ (Package.swift depends on ../vendor/SwiftTerm), apply
# the mutation to the copy's shipped source, confirm the file's checksum changed, run
# the copy's check-tree-refresh.sh in normal mode. The real tree is never written.
#
# EXIT CONTRACT
#   0  every mutant was caught (copied gate exited 1)
#   1  at least one mutant was NOT caught (copied gate exited 0)
#   2  environmental: copy failed, a mutation did not change its file, the copied gate
#      exited 2, or no mutant ran at all. Never 0 when nothing ran.
#

set -uo pipefail

cd "$(dirname "$0")/.."
APP="$(pwd)"
REPO="$(cd .. && pwd)"
[[ -d "$REPO/vendor" ]] || { echo "error: $REPO/vendor missing" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "error: python3 not found" >&2; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
SRC="Sources/GoblinPortal"

# mutate <file> <old> <new>: literal, exactly-once replacement in the copy.
mutate() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
if s.count(old) != 1:
    sys.exit(3)
open(path, "w").write(s.replace(old, new))
PY
}

# Each mutant writes one verdict line (CAUGHT/MISSED/ENV/...) to $TMP/<name>.verdict.
# They run CONCURRENTLY (each copy does an incremental rebuild plus a gate run, ~20s;
# all four together ~30s measured). A mutant that puts listing back on main used to
# hang the gate; the stub's 2s wait timeout (check-tree-refresh-cases.swift) bounds it.
# FALSIFY_ONLY=<name> runs a single mutant.

# run_mutant <name> <file-relative-to-app> <old> <new>
run_mutant() {
  [[ -z "${FALSIFY_ONLY:-}" || "$FALSIFY_ONLY" == "$1" ]] || return 0
  _run_mutant "$@" > "$TMP/$1.verdict" 2>&1 &
}
_run_mutant() {
  local name="$1" rel="$2" old="$3" new="$4"
  local work="$TMP/$name"
  mkdir -p "$work"
  if ! cp -cR "$APP" "$work/app" 2>/dev/null && ! cp -R "$APP" "$work/app"; then
    echo "  ENV   $name: copy of app/ failed"; return
  fi
  ln -s "$REPO/vendor" "$work/vendor"
  local file="$work/app/$rel"
  local before after
  before="$(shasum "$file" | cut -d' ' -f1)"
  mutate "$file" "$old" "$new"
  after="$(shasum "$file" | cut -d' ' -f1)"
  if [[ "$before" == "$after" ]]; then
    echo "  ENV   $name: mutation did not change $rel (anchor text drifted?)"
    rm -rf "$work"; return
  fi
  local out status
  out="$("$work/app/Scripts/check-tree-refresh.sh" 2>&1)"; status=$?
  local hit
  hit="$(echo "$out" | grep -E '^  FAIL ' | sed 's/^  FAIL //; s/:.*//' | tr '\n' ' ')"
  case $status in
    1) echo "  CAUGHT $name (exit 1) by: $hit" ;;
    0) echo "  MISSED $name (exit 0) — gate stayed green on a known bug" ;;
    *) echo "  ENV   $name: copied gate exited $status"; echo "$out" | tail -5 | sed 's/^/        /' ;;
  esac
  rm -rf "$work"
}

echo "==> falsify: 4 mutants against copies of app/"

# 1. Generation check removed: a landing is applied however stale its token.
run_mutant no-generation "$SRC/FileTreeViewController+Loading.swift" \
  'guard generation == treeLoadGeneration, issuedRoot === root else {' \
  'guard issuedRoot === root else {'

# 2. Identity loss: every reconcile recreates every child.
run_mutant identity-loss "$SRC/FileNode.swift" \
  '                    return reused
' \
  '                    _ = reused
'

# 3. A current landing applied during an inline edit instead of deferred.
run_mutant apply-during-edit "$SRC/FileTreeViewController+Loading.swift" \
  '        guard !isEditingInline else {
            TreeRefreshTiming.note(site: site,' \
  '        guard true else {
            TreeRefreshTiming.note(site: site,'

# 4. setRoot lists synchronously on main again.
run_mutant sync-setroot "$SRC/FileTreeViewController.swift" \
  '        beginRootLoad()' \
  '        root.reloadChildren(); outlineView.reloadData()'

wait
ran=0; caught=0; missed=0; env=0
for v in "$TMP"/*.verdict; do
  [[ -f "$v" ]] || continue
  cat "$v"
  if grep -q '^  CAUGHT ' "$v"; then ran=$((ran + 1)); caught=$((caught + 1))
  elif grep -q '^  MISSED ' "$v"; then ran=$((ran + 1)); missed=$((missed + 1))
  else env=$((env + 1)); fi
done
echo
echo "falsify: ran=$ran caught=$caught missed=$missed environmental=$env"
if (( ran == 0 || env > 0 )); then exit 2; fi
if (( missed > 0 )); then exit 1; fi
exit 0
