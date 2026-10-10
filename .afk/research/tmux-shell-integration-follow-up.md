# Follow-up: OSC 7 / OSC 133 through tmux via DCS passthrough

**Status:** draft GitHub issue body — do not file yet.

---

## Summary

`shell-integration.zsh` stays silent inside tmux because `TERM_PROGRAM=tmux` causes
the early-return at line 24 (measured on tmux 3.6a, 2026-10-09). This is correct
behaviour: an unprotected OSC 7 sent from inside tmux would be consumed by tmux
itself rather than passed to the outer terminal. However, tmux has supported an
opt-in DCS passthrough mechanism since tmux 3.2:

```
set -g allow-passthrough on   # in tmux.conf
```

With that option set, a sequence wrapped as `ESC P tmux; <base64> ST` passes
through to the outer terminal. SwiftTerm patch `0005` already unwraps these DCS
Ptmux sequences (`PtmuxDcsHandler.swift`). The missing piece is that the shell
integration script does not yet know to wrap its sequences when running inside tmux.

## What would be needed

1. **Shell script detection.** In `shell-integration.zsh`, detect `$TMUX` (set by tmux
   for any shell it starts). When set and `allow-passthrough` is on, wrap OSC 7 and
   OSC 133 output in the DCS Ptmux envelope:
   ```sh
   printf '\eP tmux;\e\\%s\e\\\e\\' "$(printf '\e]7;file://%s%s\a' "$HOSTNAME" "$PWD")"
   ```
   (tmux doubles literal `ESC` bytes inside the payload; the wrapper must escape them.)

2. **Attribution ambiguity.** The current passthrough mechanism has a fundamental
   limitation: tmux delivers the last sequence it received on any pane, not
   necessarily the sequence from the active pane. If two panes both run the
   integration script and both `cd` quickly, the outer terminal may receive the
   second pane's OSC 7 report while the first pane is active. The sidebar would
   then follow the wrong pane. This is not a defect in the implementation; it is
   a property of how tmux routes passthrough. Documenting it as a known gap is
   the right response for now.

3. **bash and fish.** `shell-integration.zsh` is the only integration script
   shipped. A follow-up that adds passthrough support should also consider:
   - `shell-integration.bash` — bash 4+ is common on Linux and macOS with
     Homebrew; the prompt hook mechanism is `PROMPT_COMMAND`.
   - `shell-integration.fish` — fish has `fish_prompt` functions and `--on-event`
     hooks; its variable `TERM_PROGRAM` can be read the same way.

4. **zellij.** zellij also sets its own `TERM_PROGRAM` value and supports a
   similar passthrough mechanism. Its syntax differs from tmux's DCS Ptmux format.
   A zellij-specific branch would need testing against zellij's actual passthrough
   handling.

5. **screen.** GNU screen supports the `DCS` pass-through with `\eP` sequences
   under `msgwait 0` and screen's own `truecolor` configuration. The passthrough
   syntax differs again. This would require a separate detection path.

## Dependency

`TmuxDirectory.swift` currently provides the active-pane directory without any
cooperation from the shell, by running `tmux display-message -c <tty>` on a
background queue (~4 ms measured). Passthrough-based OSC 7 would complement this
by providing instant notification (no 750 ms poll latency) but would require
opt-in by the user (`allow-passthrough on`). Both mechanisms can coexist:

- passthrough OSC 7 → immediate update, opt-in, attribution-ambiguous for >1 active pane
- tmux subprocess poll → ~750 ms latency, always-on, attribution-exact

The right design is probably to use passthrough OSC 7 as the fast path when the
signal arrives, while keeping the poll as the correct-attribution backstop.

## #158 follow-up: sorting children off-main

The baseline (`tree-refresh-baseline-2026-10-09.md`) measured the remaining
~35 ms of main-thread work in `refresh()` after the listing is moved off-main.
That work is:

- Reconcile `FileNode` identities (match old nodes to new entries by URL + flags).
- Localized sort of ~3,000 children across 300 expanded directories
  (`compare(_:_:)` calls `localizedStandardCompare`).
- `outlineView.reloadData()`.
- Re-expand 300 rows.

The sort is the dominant cost and is pure over value types. Moving it off-main —
sorting the `[DirectoryEntry]` array returned by the lister before it lands on
main, then reconciling identities on main with a pre-sorted input — would eliminate
most of the remaining stall. This is a bounded refactor: the reconciliation loop
in `FileTreeViewController+Loading.swift` would need the sorted input, and
`DirectoryEntry` is already `Sendable` by construction (a struct of value types).
The expansion replay and `reloadData` must remain on main.

Estimated reduction: 35 ms → ~5–10 ms (the reloadData + expansion cost alone),
based on the profile breakdown in `tree-refresh-baseline-2026-10-09.md`.
