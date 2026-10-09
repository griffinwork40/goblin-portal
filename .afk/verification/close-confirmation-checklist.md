# T2.1 verification

2026-10-09, branch afk/iso-compose-t2-1-confirm-close-1-noaixi.

## Automated observations

All final commands exit 0: swift build, check-file-size.sh, check-afk-loc.sh,
check-close-confirm.sh, check-cwd-follow.sh, check-pane-teardown.sh,
check-standard-menus.sh, check-palette-covers-menu.sh, git diff --check.

The close gate compiles shipped CloseConfirmPolicy and ShellDirectory. Its mutant
counts unique names instead of jobs and exits 1 as required. Python forkpty fixtures
exercise an idle zsh and a real separate sleep foreground group. Interactive zsh
job launch proved unreliable under this runner's inherited environment, so the busy
fixture explicitly creates and foregrounds a process group instead of claiming to
exercise interactive shell job control.

An offscreen @testable smoke harness linked current shipping objects and exited 0:
aggregate names/dedup/quit flag; no individual terminal re-prompts; Space includes
peers; Cancel preserves tab and split; confirmation tears down peer only on split
collapse and tab on tab close; unstarted TerminalPane closes silently. Harness is
in app/.build/t21-routing.swift (ignored scratch), not a standing regression gate.

## Daily-drive checklist (not claimed verified)

* ⌘W and tab × with vim, npm, afk and ssh warn once; idle prompt closes silently.
* Nested split focus: warning names every actual victim, cancellation changes nothing.
* Two Spaces with repeated process names: ⌘Q shows one warning with total job count.
* Return and Escape both cancel; Close/Quit is visibly destructive.
* Process warning Cancel never opens an editor Save dialog. On acceptance, existing
  editor Save/Cancel behaviour remains. Cancelling a later file cannot undo an earlier Save.
* Process exits or another begins while a modal warning is displayed: observation
  is a snapshot, not a freeze of process state.
* Shell exec replacement warns; symlink shell config resolves to its real basename.
* Retained exited panes from T2.2 close without warning; restart refreshes spawn identity.
