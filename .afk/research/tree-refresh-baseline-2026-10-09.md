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
