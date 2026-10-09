#!/bin/bash
#
# check-tree-refresh-baseline.sh — wall-clock baseline for setRoot/refresh (#158).
#
# WHAT IT MEASURES
#   FileTreeViewController.setRoot(url) and .refresh() with GOBLIN_PORTAL_DIAG=1,
#   parsing the [diag] tree-refresh: lines from stderr.  Two trees are tested:
#     [A] synthetic: ~40k files across ~3k dirs, ~300 dirs expanded
#     [B] agent-afk/node_modules: 30 338 entries, 2 834 dirs (read-only)
#   10 samples per (site, tree) pair → median / p95 / max reported.
#
# EXIT CODES
#   0  all measurements complete; markdown written to .afk/research/
#   2  environmental: build failed, binary missing, node_modules absent
#
# WHAT BLOCKS MAIN (today, before async work)
#   setRoot and refresh call reloadChildren() synchronously on the main thread.
#   This script records that baseline so the async PR (#158) can show improvement.
#

set -uo pipefail

QUIET="${QUIET:-0}"
say() { [[ "$QUIET" == "1" ]] || echo "$@"; }

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
HARNESS="$ROOT/Scripts/check-tree-refresh-baseline-harness.swift"
PRODUCTS="$ROOT/.build/out/Products/Debug"
OUT_DIR="$ROOT/../.afk/research"
OUT_MD="$OUT_DIR/tree-refresh-baseline-2026-10-09.md"
NODE_MODULES="/Users/griffinlong/Projects/open_source/agent-afk/node_modules"

command -v swiftc >/dev/null 2>&1 || { echo "error: swiftc not found" >&2; exit 2; }
[[ -f "$HARNESS" ]] || { echo "error: harness not found: $HARNESS" >&2; exit 2; }
[[ -d "$NODE_MODULES" ]] || {
  echo "error: node_modules not found at $NODE_MODULES" >&2; exit 2; }

BFLAGS=()
swift build --help 2>&1 | grep -q -- '--build-system' && BFLAGS=(--build-system swiftbuild)

say "==> building"
if ! swift build "${BFLAGS[@]}" >/dev/null 2>&1; then
  echo "error: swift build failed" >&2
  swift build "${BFLAGS[@]}" 2>&1 | grep 'error' | head -10 >&2
  exit 2
fi

TOBJ="$(find "$ROOT/.build/out/Intermediates.noindex" -type d \
  -path '*/GoblinPortal-p.build/Objects-normal/*' 2>/dev/null | head -1)"
[[ -n "$TOBJ" && -f "$TOBJ/FileTreeViewController.o" ]] || {
  echo "error: GoblinPortal objects not found" >&2; exit 2; }
[[ -e "$PRODUCTS/SwiftTerm.o" ]] || {
  echo "error: SwiftTerm.o missing" >&2; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Compile harness (renamed main.swift so swiftc sees entry point).
cp "$HARNESS" "$TMP/main.swift"
OBJS=$(ls "$TOBJ"/*.o | grep -v '/main\.o$' | tr '\n' ' ')
say "==> compiling harness"
if ! swiftc -o "$TMP/baseline" "$TMP/main.swift" \
    -I "$TOBJ" -I "$PRODUCTS" -I "$PRODUCTS/include" -L "$PRODUCTS" \
    $OBJS "$PRODUCTS/SwiftTerm.o" \
    -framework AppKit 2>"$TMP/compile.log"; then
  echo "error: harness compile failed" >&2
  grep 'error' "$TMP/compile.log" | head -10 >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Generate synthetic tree: ~40 000 files across ~3 000 dirs.
# Layout: 3000 dirs (100 top-level × 30 subdirs) × ~13 files each = 39 000 files
# plus 3000 dirs themselves → total entries ~42 000.
# ---------------------------------------------------------------------------
say "==> generating synthetic tree (~40k files / ~3k dirs)"
SYN="$(mktemp -d "$TMP/synthetic.XXXXXX")"
for top in $(seq -w 1 100); do
  for sub in $(seq -w 1 30); do
    d="$SYN/dir$top/sub$sub"
    mkdir -p "$d"
    for f in $(seq 1 13); do
      echo "$top-$sub-$f" > "$d/file$f.txt"
    done
  done
done
SYN_COUNT=$(find "$SYN" | wc -l | tr -d ' ')
SYN_DIRS=$(find "$SYN" -type d | wc -l | tr -d ' ')
say "==> synthetic tree: $SYN_COUNT entries, $SYN_DIRS dirs"

# ---------------------------------------------------------------------------
# Run measurement for one tree; capture DIAG stderr lines.
# Prints "[diag] tree-refresh: site=X dirs=N elapsed=Y.Zms" lines.
# ---------------------------------------------------------------------------
run_tree() {
  local path="$1" tag="$2" expand="$3"
  say "==> measuring tree=$tag (expand=$expand)"
  GOBLIN_PORTAL_DIAG=1 "$TMP/baseline" "$path" "$tag" "$expand" \
    2>"$TMP/diag-$tag.log"
  cat "$TMP/diag-$tag.log"   # let say() see it in verbose mode
}

UPTIME_STR="$(uptime)"
run_tree "$SYN"          "synthetic"    300
run_tree "$NODE_MODULES" "node_modules" 300

# ---------------------------------------------------------------------------
# Parse DIAG lines → compute stats with awk.
# Line format: [diag] tree-refresh: site=X dirs=N elapsed=Y.Zms
# We emit: site tree p50 p95 max samples
# ---------------------------------------------------------------------------
parse_stats() {
  local tag="$1"
  # BSD awk (macOS): no gawk-style match capture groups, no multidimensional arrays.
  # Use composite keys "site:idx" and a separate count[] array.
  awk -v tag="$tag" '
  /\[diag\] tree-refresh: site=/ && /elapsed=/ {
    s = $0; sub(/.*site=/, "", s); split(s, a, " "); site = a[1]
    e = $0; sub(/.*elapsed=/, "", e); sub(/ms.*/, "", e); ms = e+0
    idx = count[site]++
    vals[site ":" idx] = ms
  }
  END {
    for (site in count) {
      n = count[site]
      # copy into a sortable array
      for (i=0; i<n; i++) tmp[i] = vals[site ":" i]
      # bubble sort
      for (i=0; i<n; i++)
        for (j=i+1; j<n; j++)
          if (tmp[j] < tmp[i]) { t=tmp[i]; tmp[i]=tmp[j]; tmp[j]=t }
      p50 = tmp[int(n*0.50)]
      p95i = int(n*0.95); if (p95i >= n) p95i = n-1
      p95 = tmp[p95i]
      mx  = tmp[n-1]
      printf "| %-12s | %-14s | %7.1f | %7.1f | %7.1f | %3d |\n", \
        site, tag, p50, p95, mx, n
      delete tmp
    }
  }' "$TMP/diag-$tag.log"
}

# Expanded counts from the diag log (first baseline: line says "expanded=N")
EXPANDED_SYN=$(grep -o 'expanded=[0-9]*' "$TMP/diag-synthetic.log"    | head -1 | cut -d= -f2)
EXPANDED_NM=$(grep  -o 'expanded=[0-9]*' "$TMP/diag-node_modules.log" | head -1 | cut -d= -f2)

# ---------------------------------------------------------------------------
# Write markdown report.
# ---------------------------------------------------------------------------
mkdir -p "$OUT_DIR"
cat > "$OUT_MD" << MDEOF
# Tree-Refresh Baseline — $(date '+%Y-%m-%d')

**Issue:** #158 — async directory listing seam

**Machine:** M4 Pro  
**Uptime / load at run time:** ${UPTIME_STR}

## What blocks main today

Both \`setRoot(url)\` and \`refresh()\` call \`reloadChildren()\` synchronously on
the main thread via \`DirectoryListing.lister\` (the new seam, step 1).
The seam is the injection point the async PR will use.

## Trees tested

| Tree | Entries | Dirs | Expanded dirs |
|------|---------|------|---------------|
| synthetic | ~$SYN_COUNT | ~$SYN_DIRS | ${EXPANDED_SYN:-?} |
| node_modules | 30 338 | 2 834 | ${EXPANDED_NM:-?} |

## Wall-clock results (ms, main-thread blocking, GOBLIN_PORTAL_DIAG=1)

| site | tree | p50 ms | p95 ms | max ms | N |
|------|------|-------:|-------:|-------:|---|
$(parse_stats synthetic)
$(parse_stats node_modules)

## Sites that block main (synchronous today)

From FileNode.swift and FileTreeViewController.swift — all call
\`reloadChildren()\` which calls \`DirectoryListing.lister\` synchronously:

- \`refresh()\` — FileTreeViewController.swift:186  
- \`setRoot(_:)\` — FileTreeViewController.swift:253  
- \`loadView()\` — FileTreeViewController.swift:167  
- \`reveal(_:)\` — FileTreeViewController.swift:325  
- \`walk(to:)\` — +Mutation.swift:174  
- \`insertPlaceholder\` — +Mutation.swift:194  
- \`shouldExpandItem\` — +OutlineView.swift:43  
- \`collectVisible\` — +Filter.swift:131  

Of these, \`refreshAfterMutation\` (+Mutation.swift:138) must stay synchronous.

## Raw DIAG output

### synthetic
\`\`\`
$(cat "$TMP/diag-synthetic.log")
\`\`\`

### node_modules
\`\`\`
$(cat "$TMP/diag-node_modules.log")
\`\`\`
MDEOF

say "==> baseline written: $OUT_MD"
say "==> done"
exit 0
