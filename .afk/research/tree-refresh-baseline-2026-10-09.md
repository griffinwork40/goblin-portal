# Tree-Refresh Baseline — 2026-10-09

**Issue:** #158 — async directory listing seam

**Machine:** M4 Pro  
**Uptime / load at run time:** 15:34  up 20:01, 1 user, load averages: 5.58 8.06 10.35

## What blocks main today

Both `setRoot(url)` and `refresh()` call `reloadChildren()` synchronously on
the main thread via `DirectoryListing.lister` (the new seam, step 1).
The seam is the injection point the async PR will use.

## Trees tested

| Tree | Entries | Dirs | Expanded dirs |
|------|---------|------|---------------|
| synthetic | ~42101 | ~3101 | 300 |
| node_modules | 30 338 | 2 834 | 190 |

## Wall-clock results (ms, main-thread blocking, GOBLIN_PORTAL_DIAG=1)

| site | tree | p50 ms | p95 ms | max ms | N |
|------|------|-------:|-------:|-------:|---|
| refresh      | synthetic      |    85.8 |    91.2 |    91.2 |  11 |
| setRoot      | synthetic      |     2.1 |     2.4 |     2.4 |  10 |
| refresh      | node_modules   |    68.9 |    69.4 |    69.4 |  11 |
| setRoot      | node_modules   |     0.8 |     1.0 |     1.0 |  10 |

## Sites that block main (synchronous today)

From FileNode.swift and FileTreeViewController.swift — all call
`reloadChildren()` which calls `DirectoryListing.lister` synchronously:

- `refresh()` — FileTreeViewController.swift:186  
- `setRoot(_:)` — FileTreeViewController.swift:253  
- `loadView()` — FileTreeViewController.swift:167  
- `reveal(_:)` — FileTreeViewController.swift:325  
- `walk(to:)` — +Mutation.swift:174  
- `insertPlaceholder` — +Mutation.swift:194  
- `shouldExpandItem` — +OutlineView.swift:43  
- `collectVisible` — +Filter.swift:131  

Of these, `refreshAfterMutation` (+Mutation.swift:138) must stay synchronous.

## Raw DIAG output

### synthetic
```
[diag] tree-refresh: site=refresh dirs=0 elapsed=2.7ms
baseline: tree=synthetic expanded=300
[diag] tree-refresh: site=setRoot dirs=0 elapsed=0.9ms
[diag] tree-refresh: site=setRoot dirs=0 elapsed=2.2ms
[diag] tree-refresh: site=setRoot dirs=0 elapsed=0.6ms
[diag] tree-refresh: site=setRoot dirs=0 elapsed=2.4ms
[diag] tree-refresh: site=setRoot dirs=0 elapsed=0.7ms
[diag] tree-refresh: site=setRoot dirs=0 elapsed=2.4ms
[diag] tree-refresh: site=setRoot dirs=0 elapsed=0.9ms
[diag] tree-refresh: site=setRoot dirs=0 elapsed=2.1ms
[diag] tree-refresh: site=setRoot dirs=0 elapsed=0.9ms
[diag] tree-refresh: site=setRoot dirs=0 elapsed=2.2ms
[diag] tree-refresh: site=refresh dirs=300 elapsed=81.8ms
[diag] tree-refresh: site=refresh dirs=300 elapsed=86.4ms
[diag] tree-refresh: site=refresh dirs=300 elapsed=83.7ms
[diag] tree-refresh: site=refresh dirs=300 elapsed=85.8ms
[diag] tree-refresh: site=refresh dirs=300 elapsed=86.2ms
[diag] tree-refresh: site=refresh dirs=300 elapsed=85.2ms
[diag] tree-refresh: site=refresh dirs=300 elapsed=87.2ms
[diag] tree-refresh: site=refresh dirs=300 elapsed=85.8ms
[diag] tree-refresh: site=refresh dirs=300 elapsed=91.2ms
[diag] tree-refresh: site=refresh dirs=300 elapsed=86.3ms
```

### node_modules
```
[diag] tree-refresh: site=refresh dirs=0 elapsed=0.9ms
baseline: tree=node_modules expanded=190
[diag] tree-refresh: site=setRoot dirs=0 elapsed=0.2ms
[diag] tree-refresh: site=setRoot dirs=0 elapsed=1.0ms
[diag] tree-refresh: site=setRoot dirs=0 elapsed=0.2ms
[diag] tree-refresh: site=setRoot dirs=0 elapsed=0.9ms
[diag] tree-refresh: site=setRoot dirs=0 elapsed=0.2ms
[diag] tree-refresh: site=setRoot dirs=0 elapsed=0.8ms
[diag] tree-refresh: site=setRoot dirs=0 elapsed=0.4ms
[diag] tree-refresh: site=setRoot dirs=0 elapsed=0.8ms
[diag] tree-refresh: site=setRoot dirs=0 elapsed=0.3ms
[diag] tree-refresh: site=setRoot dirs=0 elapsed=1.0ms
[diag] tree-refresh: site=refresh dirs=190 elapsed=69.2ms
[diag] tree-refresh: site=refresh dirs=190 elapsed=69.1ms
[diag] tree-refresh: site=refresh dirs=190 elapsed=65.8ms
[diag] tree-refresh: site=refresh dirs=190 elapsed=69.4ms
[diag] tree-refresh: site=refresh dirs=190 elapsed=68.3ms
[diag] tree-refresh: site=refresh dirs=190 elapsed=68.9ms
[diag] tree-refresh: site=refresh dirs=190 elapsed=69.2ms
[diag] tree-refresh: site=refresh dirs=190 elapsed=62.0ms
[diag] tree-refresh: site=refresh dirs=190 elapsed=66.7ms
[diag] tree-refresh: site=refresh dirs=190 elapsed=69.3ms
```

## After #158: async refresh() and setRoot listing (re-measured 2026-10-09)

Same script and trees (`TREE_REFRESH_OUT=/tmp/... ./Scripts/check-tree-refresh-baseline.sh`),
with expanded dirs at 300 (synthetic) and 190 (node_modules). The harness now pumps
0.4s between calls, because a newer call issued before the last one landed would drop
it as stale; no `dropped`/`deferred` lines appeared in the run. Load averages were
4.98 7.03 7.55.
`refresh`/`setRoot` = **main-thread** time (issue half plus landing: reconcile, sort,
reloadData, restore expansion and selection). `*-list` = the **off-main** listing,
which no longer blocks main.

| site | tree | p50 ms | p95 ms | max ms | N |
|------|------|-------:|-------:|-------:|---|
| refresh (main)      | synthetic    |  38.6 |  39.6 |  39.6 | 11 |
| refresh-list (bg)   | synthetic    |  56.7 |  57.7 |  57.7 | 11 |
| setRoot (main)      | synthetic    |   1.3 |   1.4 |   1.4 | 10 |
| setRoot-list (bg)   | synthetic    |   1.1 |   1.1 |   1.1 | 10 |
| refresh (main)      | node_modules |  31.8 |  32.9 |  32.9 | 11 |
| refresh-list (bg)   | node_modules |  38.5 |  40.1 |  40.1 | 11 |
| setRoot (main)      | node_modules |   0.3 |   0.7 |   0.7 | 10 |
| setRoot-list (bg)   | node_modules |   0.6 |   0.7 |   0.7 | 10 |

**Before → after, main thread, p50:** refresh 85.8 → 38.6 ms (synthetic) and
68.9 → 31.8 ms (node_modules). setRoot 2.1 → 1.3 ms and 0.8 → 0.3 ms, and its
listing (seconds on SMB/iCloud) is now entirely off main. The remaining ~35 ms of
refresh is main-actor work over FileNode objects (reconcile plus localized sort of
about 3k children across 300 dirs, `reloadData`, and re-expanding 300 rows). It is
a follow-up candidate: sort off-main inside the listing, and restore expansion
incrementally.

Still synchronous on main by design: loadView (first frame), reveal(_:),
walk(to:), insertPlaceholder, disclosure (shouldExpandItem), the filter's
collectVisible, and refreshAfterMutation → refreshSynchronously().
