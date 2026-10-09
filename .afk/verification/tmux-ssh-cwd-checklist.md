# Manual checklist — tmux/ssh cwd follow, typing guard, indicator rendering

Items on this list are things no `check-*.sh` gate can reach, either because they
require a real remote session, a real tmux installation with real I/O, or because they
exercise AppKit layout and rendering (themes, VoiceOver, narrow sidebar). A tick here
is a one-off observation, not a standing check; anything that turns out to be
mechanically verifiable belongs in a gate, not here.

---

## Real ssh session

- [ ] Open a terminal pane and start `ssh user@host` (any reachable machine).
  - [ ] A note appears above the file tree: "following paused: ssh" (or "remote: host"
        if the remote shell immediately sends OSC 7).
  - [ ] ⌘T opens a new tab rooted at the Space root, not at any path that was visible
        before the ssh.
  - [ ] Right-click a file → "cd Here" produces a beep and no bytes are sent to the
        terminal.
  - [ ] ⌘⇧C (Send Path) and ⌘⇧R (Run in Terminal) are greyed out in the menu.
- [ ] Exit the ssh session.
  - [ ] The note disappears and the sidebar returns to following the local shell.
  - [ ] ⌘⇧C and ⌘⇧R become enabled again.

## Remote OSC 7 (remote shell sends its own path)

- [ ] Connect to a remote machine that has `GOBLIN_PORTAL_INTEGRATION` set (or
      manually source `shell-integration.zsh` and override `TERM_PROGRAM`).
  - [ ] The note shows "remote: \<host\>" — the host is the remote machine's name from
        the OSC 7 URL.
  - [ ] A path on the remote machine that happens to spell out a real local path (e.g.
        `/tmp`) does NOT cause the sidebar to re-root at that local path. The note stays
        visible and the tree stays where it was.

## tmux

- [ ] Start tmux in a terminal pane (production socket, no special flags).
  - [ ] The sidebar follows the tmux active pane's directory. The first answer may take
        up to about 750 ms (one poll interval) from attach.
  - [ ] Switching tmux windows (prefix `,n`, prefix `,p`) moves the sidebar to the new
        active pane's directory within at most one poll interval (~750 ms).
  - [ ] Switching tmux panes (prefix `,arrow`) likewise moves the sidebar.
  - [ ] Running `cd /some/path` inside a tmux pane moves the sidebar to that path
        (within one poll).
- [ ] Switch between two different tmux client sessions (prefix `,d` detach, re-attach
      from a different pane). The second attach moves the sidebar to that client's active
      pane within at most one additional poll.
- [ ] Detach from tmux (prefix `,d`).
  - [ ] The sidebar returns to following the outer shell. No stale tmux path persists.

## Typing-guard with vim/python3/agent-afk in front

- [ ] Inside a tmux pane, start vim (or python3, or agent-afk).
  - [ ] All four terminal-directed actions are refused with a beep:
    - [ ] Insert Path (⌥-double-click or context menu).
    - [ ] cd Here (context menu).
    - [ ] Send Path to Terminal (⌘⇧C).
    - [ ] Run in Terminal (⌘⇧R) — menu item is greyed out.
  - [ ] This reflects the documented residual limit: the outer pty cannot see inside
        tmux, so the guard allows `.tmuxClient` in front but cannot verify the active
        pane is safe. The note in the sidebar still says "following: tmux" (or similar).

## screen and zellij

- [ ] Start `screen` in a terminal pane.
  - [ ] The note appears: "following paused: screen".
  - [ ] The sidebar tree does not move while you navigate inside screen.
- [ ] Exit screen. The note disappears and the shell resumes following.
- [ ] Same sequence with `zellij` if available.

## Indicator rendering

- [ ] Under **classic-repaired** theme: the follow-status note is legible (11pt
      secondary-colour text, no background, readable against the sidebar vibrant material).
- [ ] Under **umber** theme: same check.
- [ ] Under **afk-light** theme: same check (the sidebar is light; the note should still
      be visible in `.secondaryLabelColor`).
- [ ] **Narrow sidebar**: drag the sidebar/editor divider to its minimum usable width.
  - [ ] The note is not clipped in a way that makes it unreadable or shows broken layout.
- [ ] **Full screen** (⌃⌘F): the indicator is absent (titlebar is hidden) — this is the
      same limit as the sidebar-toggle accessory; not a defect.
- [ ] **Source Control view** (⌘⇧E to switch back after ⌃⇧G): when the SCM panel is
      visible, the follow-status indicator is hidden. Switching back to Explorer shows it
      again if the status is non-local.
- [ ] **VoiceOver**: with VoiceOver on, navigate to the sidebar. VoiceOver should read
      the follow-status note (accessible description). It should NOT announce it on every
      750 ms tick if the status has not changed.

## #158 async tree on a large expanded tree

- [ ] Open a Space rooted at a large directory (e.g. a node_modules tree or a big
      monorepo). Expand 50+ folders.
- [ ] Switch away and back (or activate another app and return). The window comes up
      **immediately** — no visible stall while the listing runs. The tree refreshes
      within a second.
- [ ] Rename a file from the sidebar (Return or F2). After the rename, the tree reveals
      the renamed file correctly (refreshAfterMutation still synchronous — no stale view).
- [ ] Move a file via context menu → Move to Trash + undo from Finder, or Cut/Paste
      within the tree. The tree reflects the new state correctly.
