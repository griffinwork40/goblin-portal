#!/bin/bash
#
# check-tree-refresh-falsify.sh — mutation test for check-tree-refresh.sh (#158).
# Reached as `check-tree-refresh.sh --falsify`.
#
# WHY: a gate that passes is only evidence if it would FAIL on the bug it names. Each
# mutant below re-introduces one bug the async loaders exist to prevent
# (FileTreeViewController+Loading.swift, FileNode.swift, +Reveal.swift,
# +OutlineView.swift, FileTreeViewController.swift `setRoot`) into a COPY of app/,
# and the copy's own gate must then fail THE CASE THAT NAMES THAT BUG.
#
# CAUGHT means: the copied gate exited 1 AND at least one of the mutant's EXPECTED
# cases appears in its `  FAIL <CASE>:` output. Exit 1 alone is not enough — a mutant
# that only breaks an unrelated case (or crashes some setup) proves nothing about the
# case that claims to guard it, and is reported WRONG-CASE (counted as missed). The
# gate's own verdict stays its exit code; the FAIL lines are read only to name WHICH
# case caught the mutant.
#
# HOW: `cp -cR` (APFS clone, cheap) app/ including .build into a mktemp dir, symlink
# <tmp>/vendor to the real vendor/ (Package.swift depends on ../vendor/SwiftTerm), apply
# the mutation to the copy's shipped source, confirm the file's checksum changed, run
# the copy's check-tree-refresh.sh in normal mode. The real tree is never written.
#
# EXIT CONTRACT
#   0  every mutant was caught by one of its expected cases
#   1  at least one mutant was MISSED (copied gate exited 0) or WRONG-CASE
#   2  environmental: copy failed, a mutation did not change its file, the copied gate
#      exited something other than 0/1, or no mutant ran at all. Never 0 when nothing ran.
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

# Each mutant writes one verdict line (CAUGHT/MISSED/WRONG-CASE/ENV) to
# $TMP/<name>.verdict. They run CONCURRENTLY, at most $FALSIFY_JOBS (default 5) at a
# time — each copy does an incremental rebuild plus a ~20s gate run. A mutant that puts
# listing back on main used to hang the gate; the stub's 2s wait timeout
# (check-tree-refresh-cases.swift `stalledLister`) bounds it. FALSIFY_ONLY=<name> runs
# a single mutant.
MAXJOBS="${FALSIFY_JOBS:-5}"

# run_mutant <name> "<EXPECTED CASE ...>" <file-relative-to-app> <old> <new>
run_mutant() {
  [[ -z "${FALSIFY_ONLY:-}" || "$FALSIFY_ONLY" == "$1" ]] || return 0
  while (( $(jobs -rp | wc -l) >= MAXJOBS )); do sleep 1; done
  _run_mutant "$@" > "$TMP/$1.verdict" 2>&1 &
}
_run_mutant() {
  local name="$1" expected="$2" rel="$3" old="$4" new="$5"
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
  local hit matched="" c
  hit="$(echo "$out" | grep -E '^  FAIL ' | sed 's/^  FAIL //; s/:.*//' | tr '\n' ' ')"
  for c in $expected; do
    [[ " $hit " == *" $c "* ]] && matched="$matched $c"
  done
  case $status in
    1) if [[ -n "$matched" ]]; then echo "  CAUGHT $name by expected:$matched (all failed: $hit)"
       else echo "  WRONG-CASE $name: expected [$expected], but only [$hit] failed"; fi ;;
    0) echo "  MISSED $name (exit 0) — expected [$expected] stayed green on a known bug" ;;
    *) echo "  ENV   $name: copied gate exited $status"; echo "$out" | tail -5 | sed 's/^/        /' ;;
  esac
  rm -rf "$work"
}

L="$SRC/FileTreeViewController+Loading.swift"
echo "==> falsify: mutants against copies of app/ (≤$MAXJOBS concurrent)"

# --- staleness and deferral (#158) ---------------------------------------------------
# Generation check removed: a refresh issued before a file op lands over it.
run_mutant no-generation "MUTATION-INVALIDATES" "$L" \
  'guard generation == treeLoadGeneration, issuedRoot === root else {' \
  'guard issuedRoot === root else {'

# Identity loss: every reconcile recreates every child.
run_mutant identity-loss "IDENTITY EXPANSION" "$SRC/FileNode.swift" \
  '                    return reused
' \
  '                    _ = reused
'

# A current landing applied during an inline edit instead of deferred.
run_mutant apply-during-edit "EDIT-DEFER" "$L" \
  '        guard !isEditingInline else {
            TreeRefreshTiming.note(site: site,' \
  '        guard true else {
            TreeRefreshTiming.note(site: site,'

# A landing during an edit DROPPED rather than recorded as deferred: `pendingReload`
# is the only thing telling the two apart (the end-of-edit re-read hides the rest).
run_mutant drop-during-edit "EDIT-DEFER" "$L" \
  '            TreeRefreshTiming.note(site: site, "deferred (inline edit active)")
            pendingReload = true; return' \
  '            TreeRefreshTiming.note(site: site, "deferred (inline edit active)")
            return'

# setRoot lists synchronously on main again.
run_mutant sync-setroot "BLOCKING-SETROOT" "$SRC/FileTreeViewController.swift" \
  '        beginRootLoad()' \
  '        root.reloadChildren(); outlineView.reloadData()'

# --- review mutants 1-5 ---------------------------------------------------------------
# R1. A refresh landing re-lists on main instead of applying the background listing.
run_mutant list-at-landing "NO-MAIN-LISTING" "$L" \
  '        root.applyListings(listings)
        outlineView.reloadData()' \
  '        root.reloadChildren()
        outlineView.reloadData()'

# R1'. The same, on the setRoot (adopt) landing.
run_mutant list-at-adopt "NO-MAIN-LISTING" "$L" \
  '            root.applyListings(listings)
            adoptRoot()' \
  '            root.reloadChildren()
            adoptRoot()'

# R2. refresh() lists only the root: changes inside expanded subfolders never land.
run_mutant root-only-refresh "SUBFOLDER-REFRESH" "$L" \
  'issueListing(of: root.loadedDirectories(), site: "refresh"' \
  'issueListing(of: [root.url], site: "refresh"'

# R3. A directory the snapshot never listed is emptied instead of kept.
run_mutant empty-unlisted "EXPAND-IN-FLIGHT" "$SRC/FileNode.swift" \
  'guard isDirectory, let entries = listings[url] else { return }' \
  'guard isDirectory else { return }; let entries = listings[url] ?? []'

# R4. The async landing does not restore the selection.
run_mutant no-selection-restore "SELECTION-SURVIVES" "$L" \
  '        restore(expanded: expanded, selectedURL: selectedURL)
        // Main-thread cost only' \
  '        restore(expanded: expanded, selectedURL: nil)
        // Main-thread cost only'

# R5 (this design's form). The outline's root switches the moment setRoot is called:
# the old tree is released while its rows are still the outline's items, and the
# outline shows the new, childless root until the listing lands.
run_mutant drop-displayed-root "NO-EMPTY-FRAME" "$L" \
  '        issueListing(of: [root.url], site: "setRoot", start: ContinuousClock.now)' \
  '        displayedRoot = root; outlineView.reloadData()
        issueListing(of: [root.url], site: "setRoot", start: ContinuousClock.now)'

# --- I1-I3 ------------------------------------------------------------------------------
# I1. The data source reads `root` instead of the displayed tree.
run_mutant source-reads-root "NO-EMPTY-FRAME" "$SRC/FileTreeViewController+OutlineView.swift" \
  'private func node(for item: Any?) -> FileNode { (item as? FileNode) ?? displayedRoot }' \
  'private func node(for item: Any?) -> FileNode { (item as? FileNode) ?? root }'

# I1. The landing swaps roots without reloading: the new tree never reaches the screen.
run_mutant adopt-no-reload "NO-EMPTY-FRAME" "$L" \
  '        outlineView.reloadData()
        performPendingReveal()' \
  '        performPendingReveal()'

# I2. A reveal mid-flight walks `root` at once (the reviewed bug) instead of queueing.
run_mutant reveal-not-queued "REVEAL-IN-FLIGHT" "$SRC/FileTreeViewController+Reveal.swift" \
  'guard displayedRoot === root else { pendingReveal = url; return }' \
  'guard true else { pendingReveal = url; return }'

# I2. The queued reveal is never performed.
run_mutant reveal-never-run "REVEAL-IN-FLIGHT" "$L" \
  '        outlineView.reloadData()
        performPendingReveal()' \
  '        outlineView.reloadData()'

# I3. A synchronous refresh mid-setRoot drops B and re-reads only the displayed tree.
run_mutant sync-drops-root "SYNC-ADOPT" "$L" \
  '        if displayedRoot !== root {' \
  '        if false {'

wait
ran=0; caught=0; missed=0; env=0
for v in "$TMP"/*.verdict; do
  [[ -f "$v" ]] || continue
  cat "$v"
  if grep -q '^  CAUGHT ' "$v"; then ran=$((ran + 1)); caught=$((caught + 1))
  elif grep -qE '^  (MISSED|WRONG-CASE) ' "$v"; then ran=$((ran + 1)); missed=$((missed + 1))
  else env=$((env + 1)); fi
done
echo
echo "falsify: ran=$ran caught=$caught missed=$missed environmental=$env"
if (( ran == 0 || env > 0 )); then exit 2; fi
if (( missed > 0 )); then exit 1; fi
exit 0
