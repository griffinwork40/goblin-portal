#!/bin/bash
# check-child-sorting.sh — #207: value sorting, main-actor identity reconciliation.
# Headless: compiles SHIPPED DirectoryListing + FileNode. Pipeline checks pin the
# sort inside issueListing's background block, before its main-actor Task, and forbid
# a second sort in FileNode. Runtime cases exercise display order and identity.
# check-tree-refresh.sh separately drives the real async controller/outline.
# Exit 0 = pass, 1 = assertion failure, 2 = environment/stale mutant/no mutants.
set -uo pipefail
cd "$(dirname "$0")/.."
APP="$(pwd)"
SRC="${GATE_SRC_DIR:-$APP}/Sources/GoblinPortal"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
command -v swiftc >/dev/null && command -v python3 >/dev/null || exit 2

if [[ "${1:-}" == --falsify ]]; then
  # APFS clones only: never edit shipped source, nor treat compile failure as caught.
  python3 - "$APP" "$TMP" <<'PY'
import os, subprocess, sys
app, tmp = sys.argv[1:]
mutants = [
    ('async-unsorted', 'OFF-MAIN-PIPELINE', 'FileTreeViewController+Loading.swift',
     'listings[dir] = DirectoryListing.sorted(lister(dir))', 'listings[dir] = lister(dir)'),
    ('landing-resorts', 'LANDING-NO-SORT', 'FileNode.swift',
     'reconcile(entries)', 'reconcile(DirectoryListing.sorted(entries))'),
    ('sync-unsorted', 'SYNC-ORDER', 'FileNode.swift',
     'reconcile(DirectoryListing.sorted(DirectoryListing.lister(url)))',
     'reconcile(DirectoryListing.lister(url))'),
    ('files-first', 'VALUE-ORDER', 'DirectoryListing.swift',
     'return lhs.isDirectory }', 'return !lhs.isDirectory }'),
    ('hidden-first', 'VALUE-ORDER', 'DirectoryListing.swift',
     'return !lhs.isHidden }', 'return lhs.isHidden }'),
    ('lexical-order', 'VALUE-ORDER', 'DirectoryListing.swift',
     'lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent)',
     'lhs.url.lastPathComponent.compare(rhs.url.lastPathComponent)'),
]
for name, case, file, old, new in mutants:
    dest = os.path.join(tmp, name)
    if subprocess.run(['cp', '-cR', app, dest]).returncode:
        sys.exit(2)
    path = os.path.join(dest, 'Sources/GoblinPortal', file)
    text = open(path).read()
    if text.count(old) != 1:
        print('ENV stale mutant:', name); sys.exit(2)
    with open(path, 'w') as out: out.write(text.replace(old, new))
    env = dict(os.environ, GATE_SRC_DIR=dest)
    result = subprocess.run([os.path.join(app, 'Scripts/check-child-sorting.sh')],
                            env=env, capture_output=True, text=True)
    if result.returncode != 1 or 'FAIL ' + case not in result.stdout:
        print('MISSED/ENV', name, result.returncode, result.stdout, result.stderr)
        sys.exit(2 if result.returncode not in (0, 1) else 1)
    print('CAUGHT', name, 'by', case)
print('all 6 mutants caught by their declared cases')
PY
  exit $?
fi

# This is a structural thread-placement assertion, NOT a timing claim. The runtime
# suite below proves the shared comparator's order; check-tree-refresh covers landing.
python3 - "$SRC" <<'PY'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
def code(name):
    return re.sub(r'//[^\n]*', '', (root / name).read_text())
loading = code('FileTreeViewController+Loading.swift')
node = code('FileNode.swift')
issue = loading.split('private func issueListing(', 1)[1].split('private func land(', 1)[0]
background = issue.split('DispatchQueue.global', 1)[1].split('Task { @MainActor', 1)[0]
ok = 'for dir in dirs { listings[dir] = DirectoryListing.sorted(lister(dir)) }' in background
print(('PASS ' if ok else 'FAIL ') + 'OFF-MAIN-PIPELINE')
# FileNode is main-actor isolated: only reloadChildren may sort; apply/reconcile must
# preserve supplied order. This catches a redundant resort even if its output agrees.
landing = node.split('func applyListings(', 1)[1]
no_sort = not re.search(r'\bsorted\s*\(|localizedStandardCompare|\.sort\s*\(', landing)
print(('PASS ' if no_sort else 'FAIL ') + 'LANDING-NO-SORT')
sys.exit(0 if ok and no_sort else 1)
PY
pipeline_status=$?
[[ $pipeline_status -le 1 ]] || exit 2

cat > "$TMP/main.swift" <<'SWIFT'
import Foundation
var failures = 0
@MainActor
func check(_ ok: Bool, _ name: String) {
    print("\(ok ? "PASS" : "FAIL") \(name)")
    if !ok { failures += 1 }
}
let root = URL(fileURLWithPath: "/tmp/child-sorting", isDirectory: true)
func entry(_ name: String, _ directory: Bool = false, _ hidden: Bool = false) -> DirectoryEntry {
    DirectoryEntry(url: root.appendingPathComponent(name), isDirectory: directory, isHidden: hidden)
}
// Interleaved flags, numeric names and case distinguish localizedStandardCompare
// from lexical compare; undotted hidden names pin filesystem flags, not dot heuristics.
let input = [entry("file10"), entry("hiddenFile", false, true), entry("Folder10", true),
             entry("file2"), entry("HiddenDir", true, true), entry("folder2", true),
             entry(".env", false, true)]
let expected = ["folder2", "Folder10", "HiddenDir", "file2", "file10", ".env", "hiddenFile"]
let sorted = DirectoryListing.sorted(input)
check(sorted.map { $0.url.lastPathComponent } == expected, "VALUE-ORDER")
check(DirectoryListing.sorted([]).isEmpty, "EMPTY")
let node = FileNode(url: root, isDirectory: true)
let original = DirectoryListing.lister
DirectoryListing.lister = { _ in input }
node.reloadChildren()
DirectoryListing.lister = original
check(node.children?.map(\.name) == expected, "SYNC-ORDER")
let before = node.children ?? []
node.applyListings([root: sorted])
check(zip(before, node.children ?? []).allSatisfy { $0 === $1 }, "IDENTITY")
// Deliberately reversed input proves landing adopts order, rather than secretly
// sorting again on main. Actual loaders supply sorted entries (pipeline assertion).
node.applyListings([root: Array(sorted.reversed())])
check(node.children?.map(\.name) == Array(expected.reversed()), "ADOPT-ORDER")
let changed = sorted.map {
    DirectoryEntry(url: $0.url, isDirectory: $0.isDirectory, isHidden: !$0.isHidden)
}
node.applyListings([root: changed])
check(node.children?.allSatisfy { child in !before.contains { $0 === child } } == true, "FLAGS-REPLACE")
exit(failures == 0 ? 0 : 1)
SWIFT
if ! swiftc "$SRC/DirectoryListing.swift" "$SRC/FileNode.swift" "$TMP/main.swift" \
    -swift-version 6 -o "$TMP/gate" 2>"$TMP/compile.log"; then
  cat "$TMP/compile.log" >&2; exit 2
fi
"$TMP/gate"; runtime_status=$?
[[ $runtime_status -le 1 ]] || exit 2
[[ $pipeline_status -eq 0 && $runtime_status -eq 0 ]]
