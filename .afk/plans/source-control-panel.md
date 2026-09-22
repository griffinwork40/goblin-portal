# Source Control Panel — Full VS Code-Style SCM

## Decision Context

The prior decision doc (`git-sidebar-decision-2026-07-31.md`) explicitly REFUSED staging/committing/discarding in the GUI, backed by three independent evidence lines (low value-per-complexity for terminal users, plan-of-record refusal, LOC ceiling constraints). This plan **reverses** that decision at the operator's explicit direction (2026-09-20). The operator chose "Full VS Code Source Control: staged/unstaged sections, commit message box, stage/unstage/discard per file, push/pull — the whole thing."

## Approach

The Source Control panel is a **collapsible section in the sidebar** (inside the existing `NSSplitViewItem`), below the file tree, with a nested vertical `NSSplitView` providing a draggable divider between the two sections. Diff viewing opens as **document tabs** via the already-sanctioned `SpaceDocument` conformer shape (`GitDiffPane`). The existing `GitStatusFollow` 2s poller and `GitStatusSnapshot` (which already parses `isStaged`) supply the data — no new polling needed.

## Concrete Changes

### New Files (~15)

**Foundation-only data layer (gateable):**

| File | LOC est. | Owns |
|------|----------|------|
| `GitOperations.swift` | ~200 | `stage(path:in:)`, `unstage(path:in:)`, `discard(path:in:)`, `commit(message:in:)`, `push(in:)`, `pull(in:)`. Each spawns one git subprocess. Fail-soft, never throws. Separate from `GitStatusReader` (reader sets `GIT_OPTIONAL_LOCKS=0`, is read-only) |
| `GitDiff.swift` | ~150 | `diff(path:staged:in:) -> String`. Runs `git diff HEAD -- <path>` or `git diff --cached -- <path>` |
| `DiffParser.swift` | ~150 | Parse unified diff output into `DiffHunk`/`DiffLine` structs |

**Sidebar panel (Source Control view):**

| File | LOC est. | Owns |
|------|----------|------|
| `SourceControlViewController.swift` | ~300 | The sidebar section: commit input, staged/unstaged/untracked file lists, collapsible section headers. `NSViewController` appended to sidebar `NSSplitView` |
| `SourceControlViewController+Actions.swift` | ~200 | Stage, unstage, discard, commit, push, pull `@objc` action methods |
| `SourceControlViewController+DataSource.swift` | ~250 | `NSOutlineViewDataSource` + `NSOutlineViewDelegate` for file rows grouped by section |
| `SourceControlRowView.swift` | ~150 | Custom row with hover-reveal +/-/discard buttons |

**Diff viewer tab (SpaceDocument conformer):**

| File | LOC est. | Owns |
|------|----------|------|
| `DiffViewerPane.swift` | ~300 | Side-by-side or unified diff display. Two synced `NSTextView`s with change highlighting |
| `DiffViewerPane+Document.swift` | ~150 | `SpaceDocument` conformance: title, symbol, font zoom, teardown |
| `DiffViewerPane+Highlighting.swift` | ~200 | Green/red backgrounds for added/removed, hunk headers, line gutters |

**Wiring:**

| File | LOC est. | Owns |
|------|----------|------|
| `SpaceViewController+SourceControl.swift` | ~100 | Adds source control panel to sidebar, wires data flow from `GitStatusFollow` |
| `AppMenu+SourceControl.swift` | ~80 | Source Control submenu: Stage All, Unstage All, Commit, Push, Pull, keybindings |
| `AppDelegate+SourceControl.swift` | ~80 | `@objc` actions routing menu items to the focused space's panel |

### Modified Existing Files

| File | Change |
|------|--------|
| `FileTreeViewController.swift` | Replace `NSStackView` root with `NSSplitView` containing file tree + source control panel (~10 lines; file is at 344/350 so some extraction may be needed) |
| `SpaceViewController+DocumentConstruction.swift` | Add `addDiffDocument(for:staged:)` method (~15 lines) |
| `AFK.md` | Update "Not Built Yet" → "Shipped", update "Known Risks" (staging refusal → reversed), update architecture table, update file table |

## Key Design Decisions

1. **Sidebar placement**: Inside existing `NSSplitViewItem` so `toggleSidebar(_:)` keeps working.
2. **Section model**: Three collapsible groups — "Staged Changes", "Changes", "Untracked" — matching VS Code but with "Changes" above "Staged" (fixing VS Code's ergonomic issue where staging pushes files downward).
3. **Hover-reveal actions**: Per-file `+` (stage), `-` (unstage), discard (undo arrow) on hover.
4. **Commit input**: Multi-line `NSTextField` at top of source control panel, `⌘Enter` to commit.
5. **Push/pull**: Explicit buttons in header area (not buried in `...` menu — improving on VS Code).
6. **Diff tabs**: `DiffViewerPane: SpaceDocument` — click changed file opens diff tab.
7. **Data flow**: Existing `GitStatusFollow` 2s poller already produces `GitStatusSnapshot` with `isStaged`. Source control panel subscribes to same snapshot.
8. **Foundation-only purity**: `GitOperations`, `GitDiff`, `DiffParser` stay Foundation-only.
9. **LOC management**: All new code in new files and extension files; no ceiling violations.

## Build Waves

- **Wave 1** (parallel): `GitOperations.swift`, `GitDiff.swift`, `DiffParser.swift`
- **Wave 2** (parallel with Wave 3, depends on Wave 1): `SourceControlViewController.swift` + extensions, `SourceControlRowView.swift`
- **Wave 3** (parallel with Wave 2, depends on Wave 1): `DiffViewerPane.swift` + extensions
- **Wave 4** (depends on 2+3): Wiring — `SpaceViewController+SourceControl.swift`, `AppMenu+SourceControl.swift`, `AppDelegate+SourceControl.swift`, existing file mods
- **Wave 5**: Gate scripts, AFK.md updates, verification

## Risks

1. **LOC ceiling**: `SpaceViewController.swift` and `FileTreeViewController.swift` both at 344/350. All new code goes in extension files.
2. **Nested NSSplitView**: Vertical `NSSplitView` inside sidebar item is unusual. Fallback: `NSStackView` with manual drag handle.
3. **Destructive operations**: `discard` is irreversible → confirmation dialog. `commit` is irreversible. `push` is external.
4. **Concurrent git**: 2s poller and user operations could race. `GitOperations` serialized, triggers immediate re-poll after completion.
5. **Large repos**: Current poller ~92ms on 60k files. Diff is on-demand per file, not polled.

## Alternatives Considered

1. **Sidebar-only (no diff tabs)**: Rejected — clicking a file should show the diff.
2. **Tab-only (no sidebar panel)**: Rejected — staged/unstaged grouping and commit input need persistent sidebar.
3. **lazygit integration**: Not primary UX — goal is native macOS feel.
4. **Read-only changed-files only**: Rejected by operator.
5. **Phased (read-only first, staging later)**: Rejected by operator — full panel requested.
