# tmux / ssh cwd follow, typing-action safety, async tree refresh (#158)

Status: APPROVED 2026-10-09. Branch `afk/add-tmux-ssh-cwd` from `2df6c568`. One PR.
Orchestration produced by `/parallelize` (planner: gpt-6.1-sol), then revised by the
coordinator. Revisions below take precedence over the planner text that follows.

## Why (diagnosis, verified in-session 2026-10-09)

- `TerminalPane.currentDirectory` (`ShellHosting.swift:127-137`) returns the OSC 7 value
  first, and that value is never cleared, so once a shell has reported, nothing else is asked.
- Inside tmux, `TERM_PROGRAM=tmux` (measured, tmux 3.6a), so `shell-integration.zsh:24`
  returns early: no OSC 7 or OSC 133 from tmux panes. `allow-passthrough` defaults off.
- The kernel fallback reads the foreground process (tmux client / ssh): its launch dir.
- `parseOsc7Directory` drops the hostname: a remote OSC 7 would open a same-named local path.
- The same stale value feeds ⌘T, splits and split persistence, not just the sidebar.
- Insert Path, cd Here, ⌘⇧C, ⌘⇧R type into whatever is in front (agent-afk REPL included).
- Measured: `tmux -L <sock> display-message -p -c <client_tty> '#{pane_current_path}'`
  follows window switches and `cd`; ~4 ms per spawn.

## Coordinator decisions (override planner where they differ)

1. `currentDirectory` returns a LOCAL directory or nil, never stale or remote:
   - integrated shell or ordinary command in front: OSC 7, else the SHELL's own kernel cwd
     (the fallback no longer follows the foreground program, so never agent-afk's cwd;
     this retires the rationale at `ShellDirectory.swift:112-117`);
   - another local shell in front: that shell's cwd;
   - tmux client in front: async cache from tmux, never a blocking subprocess on main;
   - ssh / mosh / screen / zellij / unknown: nil (⌘T and splits fall back to the Space root).
2. Remote OSC 7 hosts are display-only status, never a path.
3. Sidebar shows a quiet note ("following paused: ssh" / "remote: host"); the 750 ms poller
   remains the single writer of the tree root.
4. All four typing actions are guarded (shell, other shell, tmux only); ⌘⇧R greyed out
   when unsafe; actions recheck at send time. Residual limit, documented: inside tmux the
   active pane may be vim or an agent.
5. #158: measure first; make setRoot and window-activation refresh async; file-operation
   reload stays synchronous because `refreshAfterMutation` (`+Mutation.swift:137-142`)
   walks and reveals right after `refresh()`. Preserve FileNode identity; drop stale results.

## Model assignment (revised: OpenAI usage exhausted, Anthropic available)

| Wave | Lane | Model |
|---|---|---|
| 0 | K contracts + fail-closed stubs | sonnet |
| 1 | A foreground classifier | sonnet |
| 1 | B tmux resolver | opus |
| 1 | D OSC 7 hostname | sonnet |
| 1 | G #158 async tree | opus |
| 2 | C cwd rule + tmux cache | opus |
| 2 | F typing guard | sonnet |
| 3 | E sidebar note | sonnet |
| 4 | H docs/checklist | sonnet |
| 4 | Reviews C+F, G | opus (cold context) + qwen `local` second opinion via model_complete |
| 5 | V final gates + receipt reconciliation | sonnet |

Review is within one provider; qwen findings are leads, blocking only if confirmed by an
opus reviewer or a gate. Final report must say so. Checkpoint after each wave so a usage
window reset resumes from the last finished wave.

## Risks

- Swift 6 concurrency may force broader async redesign in G: keep the synchronous path
  and document it rather than widening scope.
- tmux active-pane content is not classifiable (vim/agent inside tmux still receives text).
- Anthropic usage window: 4 opus lanes plus reviews may not fit in one window.
- Manual residue: real ssh session, indicator rendering across themes, VoiceOver.

## Alternatives considered

- OSC 7 through tmux via DCS passthrough (patch 0005 unwraps it): needs opt-in
  `allow-passthrough on`, last-printing pane wins. Deferred to a follow-up issue.
- Async file-operation reloads: break reload-then-reveal ordering. Rejected.
- Guarding only the two submitting actions: pasted text still lands in an agent prompt. Rejected.
- Remote file browsing over ssh / sshfs mapping: out of scope.

---

# Planner output (verbatim)

[subagent result · model=gpt-6.1-sol (parent: claude-opus-5-5)]

# Orchestration plan: tmux-aware cwd, honest remote state, safe terminal actions, asynchronous tree refresh

## 1. Outcome and boundaries

- Deliver **one PR** from `afk/add-tmux-ssh-cwd`.
- Every shell-cwd reader receives a **local, trustworthy directory or nil**.
- tmux follows the active pane through window switches, pane switches, and `cd`.
- Remote sessions never reinterpret a remote path as a local directory.
- Unsafe terminal-directed actions refuse rather than becoming input to a REPL/editor.
- Sidebar re-rooting and activation refresh perform directory enumeration off-main.
- Preserve tree-node identity, inline editing, expansion, selection, and mutation correctness.
- Exclude remote browsing, sshfs, agent-afk worktree following, FSEvents, and passthrough integration.
- This document is a plan, not an implementation or verification receipt.
- Research scope: read-only; no files changed and no gates executed.

## 2. Grounding and corrections

Git grounding confirms branch `afk/add-tmux-ssh-cwd`, clean, at:
`2df6c56866c53959688d7a69730a72d45706feba`.

The specialist ran `git rev-parse HEAD`, `git rev-parse --abbrev-ref HEAD`, and `git status --porcelain`.

| Claim/reference | Finding and corrected evidence |
|---|---|
| `ShellHosting.swift:127-137` | Correct: reported OSC 7 wins before checking whether the process exists. |
| OSC 7 storage `:217-231` | Correct; associated storage and restricted setter are at `TerminalPane+ShellIntegration.swift:238-244`. |
| Poller `DirectoryFollow.swift:119` | Correct; 750 ms timer is at `:74-85`, root forwarding at `:196-197`. |
| cwd readers | Correct: construction `:48`, splits `:47,83`, snapshot serialization `SplitRestore.swift:183,189,195`. |
| Script activates only for GoblinPortal | Slight correction: `shell-integration.zsh:24` also accepts backward-compatible `Umber`. |
| Host discarded | Correct: `ShellIntegration.swift:178-198` reads URL path without validating host. |
| Parser normalizes | Existing parser does **not** normalize; normalization happens in `handleOsc7Directory:227-230`. |
| `cd Here` lines 126-200 | Insert starts at `Delegates.swift:126`; cd starts at `:186`, sends at `:200`, activation continues through `:207`. |
| Run in Terminal lines 46-62 | Send Path starts `EditorActions.swift:46`; Run starts `:57`; actual submitting send is `:92`. |
| Menu validation location | It is `AppDelegate.swift:88-117`, specifically shared Send/Run validation at `:105-107`. F must own this file. |
| Mutation refresh | `Mutation.swift:122-145` calls `refresh()` and immediately walks/reveals. Making refresh async blindly breaks this sequencing. |
| `walk(to:)` | Private synchronous implementation at `Mutation.swift:159-184`; placeholder reload is at `:194`. |
| Other synchronous callers | Initial `loadView:167` and `reveal:325` also enumerate; disclosure/filter paths require inventory before G changes scope. |
| Identity preservation | `FileNode.swift:65-102` reuses only when URL **and** directory/hidden flags agree; preserve that exact qualification. |
| “350 LOC” | Reader displays 351 logical lines for the controller, but AFK records 350. Gate uses **`wc -l`**, not displayed logical-line count. |
| All gates have uniform exits | Existing exceptions: `verify-vendor.sh` uses exit 3; AFK.md:68 documents exit 3 for keys-e2e. Preserve/document existing semantics. |
| Verdict never stdout-dependent | Existing tree gate downgrades exit 1 without `FAIL` text to 2 (`check-file-tree-ops.sh:107-112`). G must remove that dependency. |
| Current integration gate coverage | It already includes OSC 7 cases (`check-shell-integration.sh:230-272`), not just OSC 133. |
| Existing cwd gate real foreground | Its spawned child tests fallback, explicitly documented at `check-cwd-follow.sh:97-107`; do not reuse its misleading opening comment as evidence. |
| Split persistence fallback | Snapshot construction writes nil cwd, not Space root. Restoration supplies fallback later; test that nil never becomes stale persisted data. |

Additional design correction: **never kernel-follow an ordinary command’s cwd** when OSC 7 is unavailable.
Read the integrated shell’s cwd instead; otherwise agent-afk’s worktree could still move the tree.
`ShellDirectory.swift:114-117` currently argues for following REPL cwd; C must retire that rationale.

The supplied tmux 3.6a timings, socket behavior, and TERM_PROGRAM observations remain supplied evidence.
They were not independently rerun in this planning session.

## 3. Frozen decisions

1. Guard **all four** actions: Insert Path, Send Path, cd Here, Run in Terminal.
2. Allow only `.shell`, `.knownShell`, `.tmuxClient`; reject unknown classification too.
3. Menu validation and action execution use the same policy; execution rechecks immediately before sending.
4. `.tmuxClient` acceptance is the requested outer-process rule, **not proof the active pane is a shell**.
5. Document that tmux hosting vim/agent-afk remains a residual safety limit; do not claim universal pane-level safety.
6. Prefer truthful `"following paused: ssh"` over inventing a remote hostname from argv.
7. Show `"remote: host"` only when a remote OSC 7 supplies an actual host.
8. Remote-host status is display-only and never participates in cwd inheritance or persistence.
9. Do not invoke tmux subprocesses synchronously from a main-actor property.
10. Use an asynchronously refreshed, client-identity-keyed tmux cache; initial/unavailable result is nil.
11. On leaving tmux, changing client identity, timeout, or detached client, invalidate cached tmux cwd.
12. G makes setRoot and ordinary refresh async; mutation reload stays explicitly synchronous initially.
13. G records the remaining synchronous mutation/disclosure/filter costs as scoped Known Risks.
14. No contract changes after Wave 0 without coordinator approval and consumer revalidation.

## 4. Interface freeze and file ownership

Wave 0 K installs buildable fail-closed stubs; subsequent owners replace bodies **sequentially**.
No two parallel lanes write a contract file.
Pure contracts import Foundation/Darwin only and have no main-actor annotation.
App-owned wrappers/protocols remain `@MainActor`.
Avoid explicit Sendable annotations under AFK.md:281; Swift 6 crossing must be compiler-verified.

### A — final owner A, `ForegroundProcess.swift`

```swift
enum ForegroundKind: Equatable {
    case shell
    case knownShell(pid: pid_t, name: String)
    case tmuxClient(pid: pid_t, tty: String)
    case remote(name: String)
    case otherMultiplexer(name: String)
    case command(name: String)
}
enum ForegroundProcess {
    static func current(
        childfd: Int32, integratedShellPid: pid_t
    ) -> ForegroundKind?
    static func classify(
        pid: pid_t, integratedShellPid: pid_t, clientTTY: String?
    ) -> ForegroundKind?
    static func clientTTY(childfd: Int32) -> String?
}
```

`current` obtains foreground pgrp; unavailable foreground information fails closed.
`classify` permits real-process gates without pretending fallback-pid tests exercise foreground selection.
Identify executables through kernel process information, not user-controlled argv display names.
`.shell` means the pane’s original shell pid; it does not claim integration-script activation.
TTY is the pane’s slave tty, not stdin of a spawned resolver.

### B — final owner B, `TmuxDirectory.swift`

```swift
enum TmuxDirectory {
    static func current(
        clientTTY: String,
        socketDirectories: [URL]? = nil,
        timeout: TimeInterval = 0.25
    ) -> URL?
}
```

Nil directories mean production discovery using TMUX_TMPDIR and platform uid socket directories.
Explicit directories constrain discovery entirely; gates must always supply isolated directories.
Every tmux command specifies an explicit socket; never invoke implicit/default-server commands.
The timeout is an **overall resolution deadline**, not a fresh allowance for each socket.
Cache server ownership only with revalidation; duplicate/ambiguous ownership returns nil.
Reject relative/empty output; normalize accepted local directory paths consistently.

### D — final owner D, `Osc7Directory.swift` and parser wrapper

```swift
enum Osc7Directory: Equatable {
    case local(path: String)
    case remote(host: String)
}
extension ShellIntegration {
    static func parseOsc7(
        _ raw: String, localHostname: String
    ) -> Osc7Directory?
    static func parseOsc7Directory(_ raw: String) -> String?
}
```

Accept empty authority, localhost, and the actual local hostname with case-insensitive exact comparison.
Do not accept arbitrary short-host suffixes, DNS aliases, or matching local path existence.
Keep the old parser signature as a wrapper returning local paths only.
Production local hostname should match zsh `$HOST`; gate the live emitted-host compatibility.
Reject malformed authority, credentials/ports, non-file schemes, and nonabsolute paths.

### C — final owner C, `ShellContext.swift`, `ShellDirectoryPolicy.swift`, `ShellHosting.swift`

```swift
enum DirectoryFollowStatus: Equatable {
    case local
    case remote(host: String?)
    case paused(program: String)
    case unavailable
}
struct ShellContext {
    let foreground: ForegroundKind?
    let directory: URL?
    let followStatus: DirectoryFollowStatus
}
enum TerminalInputPolicy {
    static func allowsTyping(into foreground: ForegroundKind?) -> Bool
}
enum ShellDirectoryPolicy {
    static func resolve(
        foreground: ForegroundKind?,
        reportedDirectory: URL?,
        integratedShellDirectory: URL?,
        knownShellDirectory: URL?,
        tmuxDirectory: URL?,
        remoteHost: String?
    ) -> ShellContext
}
```

Add to the existing `@MainActor ShellHosting` protocol:

```swift
var foregroundKind: ForegroundKind? { get }
var shellContext: ShellContext { get }
func refreshDirectoryState()
```

Keep `send(text:)` and `currentDirectory`; currentDirectory returns `shellContext.directory`.
ForegroundKind is refreshed live; it never relies solely on the directory cache.
RefreshDirectoryState schedules/coalesces tmux work and never blocks waiting for completion.
C implements its main-actor cache in `TerminalPane+DirectoryState.swift`.
`.shell/.command`: local OSC 7, otherwise integrated-shell kernel cwd.
`.knownShell`: that pid’s kernel cwd; `.tmuxClient`: valid cache only.
`.remote/.otherMultiplexer/unknown`: nil directory, appropriate display status.
C may expose `ShellDirectory.current(of:)` for direct-pid reads, retaining the old API.

### E/G seam — final owner E, `FileTreeViewController+FollowStatus.swift`

```swift
@MainActor
extension FileTreeViewController {
    func updateDirectoryFollowStatus(_ status: DirectoryFollowStatus)
}
```

E inserts a lazily owned indicator into `fileTree.view as? NSStackView`.
Use associated-object storage, following `+SourceControl.swift:66-86`.
**E never edits the base controller, +Git, +Mutation, +Timing, or +Filter.**
G preserves the root NSStackView contract, so E/G have zero parallel write collision.

## 5. Wave map, scheduling, and provider allocation

| Wave/lane | Dependencies | Model/provider | Rounds | Estimate |
|---|---|---|---:|---:|
| 0 K: contract scaffolding | grounding | gpt-6-sol / OpenAI | 80 | 15–25 min |
| 1 A: foreground classification | K | gpt-6.1-sol / OpenAI | 100 | 35–50 min |
| 1 B: tmux resolver | K | gpt-6-astra / OpenAI | 110 | 40–60 min |
| 1 D: hostname policy | K | gpt-5.6-sol / OpenAI | 80 | 20–35 min |
| 1 G: async tree + baseline | K | gpt-6.1-sol / OpenAI | 120 | 65–90 min |
| 2 C: cwd composition/cache | A+B+D | gpt-6.1-sol / OpenAI | 120 | 45–65 min |
| 2 F: typing guards | A; frozen C contracts | gpt-6-sol / OpenAI | 100 | 30–45 min |
| 3 E: indicator/poller | C; frozen G stack contract | gpt-6-luna / OpenAI | 90 | 25–40 min |
| 4 H: docs and evidence integration | C+E+F+G | gpt-5.6-sol / OpenAI | 80 | 15–25 min |
| 4 R-CF: adversarial C/F review | integrated C+F | sonnet / Anthropic | 35 | 15–25 min |
| 4 R-G: concurrency/identity review | integrated G | opus / Anthropic | 40 | 20–30 min |
| 5 V: final gates/receipt reconciliation | H + reviews resolved | gpt-6-astra / OpenAI | 100 | 25–45 min |

OpenAI carries every implementation lane because Anthropic’s 5-hour window was just exhausted.
The heavier OpenAI slugs receive process/concurrency/composition work; smaller allocations handle bounded UI/docs.
Anthropic is reserved for independent final judgment, preferably after its window resets.
If unavailable, do not block delivery indefinitely: use an external available Anthropic route or report review pending.
A different OpenAI slug is **not** a different provider; do not relabel that fallback independent-provider review.
Provider availability and slug support must be checked before dispatch; these are requested routing assignments.

All writer lanes use managed worktree isolation; no shared `.build` directories.
Start A/B/D together, then G immediately as capacity allows; avoid a single huge API dispatch burst.
Each child has a bounded timeout covering its estimate plus 20 minutes, not an unlimited session.
Allow C and F to overlap; F builds against frozen fail-closed C scaffolding and tests injected classifications.
E need not wait for G: it uses the preserved NSStackView seam.
Serialize GUI build-heavy gates within each worktree and limit concurrent whole-app builds machine-wide.

**Longest chain:** K → B → C → E → H/reviews → V.
Expected automated wall-clock: approximately **3–4.5 hours**, including fan-in gates.
G’s independent 65–90-minute lane should finish before the cwd/UI chain.
Manual SSH/UI validation and Anthropic reset can extend elapsed time; report those separately.

## 6. Dispatch rules and evidence protocol

Each brief below includes the mandatory rules; the coordinator also attaches this frozen contract section.
Within a lane, read exact content before editing; use absolute paths and quote paths containing spaces.
Each new gate supports `--falsify`; each changed existing gate gains equivalent documented invocation.
`--falsify` runs the normal assertions against temp-copy mutants and exits 0 only if each mutant exits **1**.
For GUI mutants, build an isolated temp package copy with its own output; never link original/stale objects.
Compilation failure is environmental evidence, **not** a successful red TDD run or falsification.
Record failing assertion, compile success, exact command, source fingerprint, exit code, and duration.
An independent reviewer supplies at least one additional mutant the gate author did not anticipate.
Research transcripts belong to `.afk/research/<lane>-*.md`, not source comments or stdout-only claims.

Required child return: owned files + `wc -l`; red/green commands and exits; mutant commands/exits;
environmental skips; new/updated AFK rows; contract deviations; commit SHAs; unresolved manual checks.
Commit identity: `AFK Agent <agent@agentafk.com>`.
Commit with a file: `git -c user.name="AFK Agent" -c user.email="agent@agentafk.com" commit -F "$MSGFILE"`.
Use lowercase conventional scopes and an em-dash rationale; never double-quote a markdown commit body.
No implementation child edits AFK.md; coordinator alone updates its rows before final verification.

## 7. Pasteable implementation briefs

### K — freeze interfaces and buildable scaffolding

**Task:** Install the exact frozen interfaces above, with nil/deny stubs, no feature behavior.
**Own:** new ForegroundProcess, TmuxDirectory, Osc7Directory, ShellContext, ShellDirectoryPolicy files;
ShellHosting.swift for additional requirements/default fail-closed conformance; `.afk/research/contract-freeze.md`.
**Forbidden:** all tree files, action files, AFK.md, resources, vendor/patches; no final feature implementation.
**Rules:** 350 wc-LOC ceiling in Sources/Scripts; extract whole concerns, never shave lines.
No test target/CI; gates are verification; exit 0/1/2 means pass/failure/environment, never stdout verdict.
New/changed gates require temp-copy falsification plus an independently chosen break; pure files Foundation/Darwin only.
Headers explain ownership/why; comments cite evidence; app types @MainActor; no try!, only constant unwraps; DIAG-only diagnostics.
Never touch real tmux default socket, config, or defaults; no AFK edits; use specified commit identity and commit -F.
**TDD:** create `check-shell-contracts.sh` first; compile frozen API consumers against deliberate incomplete temp stubs.
Observe compile incompleteness as scaffolding evidence only; also use a behavioral deny-stub assertion that exits 1.
Implement compile-safe deny stubs; command: `cd "$WT/app" && ./Scripts/check-shell-contracts.sh`.
Falsify a temp policy stub to allow unknown input; run `./Scripts/check-shell-contracts.sh --falsify`.
Run `./Scripts/check-file-size.sh` and `swift build`; preserve explicit “stub, not delivered” state in transcript.
**Done:** contracts compile; fail closed; owner-transfer ledger names A/B/D/C; no false feature claim.
**Return:** files+LOC, commands/exits, falsification, AFK rows, full SHAs, temporary stub inventory.

### A — real foreground classification

**Task:** Replace ForegroundProcess stubs using kernel executable identity and the owned PTY’s slave tty.
**Own:** ForegroundProcess.swift; optional ForegroundProcess+Inspection.swift; check-foreground-process.sh and split fixtures/harness.
**Forbidden:** B/D/C contracts, ShellHosting, tree/action files, AFK.md, real sockets/config/defaults, vendor.
**Rules:** 350 wc-LOC ceiling; extract concerns, never shave; no tests/CI; gate exits are verdicts.
Every changed gate requires temp-copy falsification and an independently chosen break; pure files Foundation/Darwin only.
New headers explain ownership; why comments cite evidence; app wrappers @MainActor; no try!/runtime unwraps; DIAG-only diagnostics.
No real tmux default socket/config/defaults; no AFK edits; specified AFK identity, lowercase scoped em-dash commits via -F.
**TDD:** `cd "$WT/app" && ./Scripts/check-foreground-process.sh` must exit 1 against K stubs.
Spawn real zsh/bash, a non-shell command, and real ssh against an isolated loopback fixture when feasible.
For optional binaries, distinguish classification mapping fixtures from actually spawned executable evidence.
Use a small isolated PTY helper issuing TIOCSCTTY or real SwiftTerm process; do not claim posix_spawn fallback proves foreground.
Cover original shell, alternate shell, exited pid, invalid fd, unknown binary, tmux client tty, foreground job transition.
Protect against a command named through argv impersonating a shell; classify executable basename, not displayed command text.
Implement, rerun gate to 0; `./Scripts/check-foreground-process.sh --falsify` must catch shell-overclassification and tty misselection.
Run `./Scripts/check-cwd-follow.sh` and `./Scripts/check-file-size.sh`.
**Done:** live foreground path demonstrated, or named environmental block; unavailable classification is nil/unsafe.
**Return:** standard evidence return plus exact process/TTY fixtures and coverage gaps.

### B — isolated real-tmux resolver

**Task:** Replace TmuxDirectory stub; discover owning server by exact client tty, return active pane cwd within an overall deadline.
**Own:** TmuxDirectory.swift; optional TmuxDirectory+Subprocess.swift; check-tmux-directory.sh and split harness/fixtures.
**Forbidden:** A/D/C files, shell integration script, tree/action files, AFK.md; implicit tmux commands or real default socket.
**Rules:** 350 wc-LOC ceiling; whole-concern extraction; no test target/CI; gate exit code is verdict, not output.
Temp-copy falsification plus independently chosen break required; Foundation/Darwin-only pure code.
Ownership/why headers, evidence comments, @MainActor app wrappers, no try!/nonconstant unwraps, DIAG-only diagnostics.
Never real config/defaults/default socket; no AFK edits; AFK identity and scoped lowercase em-dash commit via -F.
**TDD:** `cd "$WT/app" && ./Scripts/check-tmux-directory.sh` exits 1 against nil stub, 2 if tmux missing.
Create unique `-L` servers under a mktemp TMUX_TMPDIR, always with explicit socket options and isolated tmux config.
Attach a **real client on a PTY**, not merely a detached server; assert fixture tty ownership.
Cases: custom socket, decoy server, window switch, pane cd, active split pane, spaces/Unicode, detach→nil.
Add stale socket, missing executable, deadline exhaustion, noisy/stalled subprocess, bounded-output behavior, and isolation assertion.
Avoid pipe deadlock: deadline includes spawn, stdout/stderr draining, termination, and bounded cleanup.
Implement; same gate exits 0; `./Scripts/check-tmux-directory.sh --falsify` catches wrong active pane and decoy/default discovery.
Run `./Scripts/check-file-size.sh`; record measured resolution times without treating supplied 4 ms as a guarantee.
**Done:** every gate socket is under temp root, no implicit/default command, timeout bounded across all candidates.
**Return:** standard evidence plus socket/client fixture ledger and timeout bounds.

### D — local-host OSC 7 acceptance

**Task:** Implement parseOsc7 and rewrite the compatible parseOsc7Directory wrapper to reject remote hosts.
**Own:** Osc7Directory.swift, ShellIntegration.swift, check-shell-integration.sh, extracted OSC harness files if necessary.
**Forbidden:** TerminalPane+ShellIntegration.swift (C owns), ShellHosting, tree/actions, AFK.md, shell-integration.zsh.
**Rules:** 350 wc-LOC ceiling; extract gate concern at ceiling, never shave; no tests/CI; verdict is exit code.
Temp-copy mutants must exit 1, including independently chosen break; pure Foundation/Darwin-only files.
Headers own/why, why comments with evidence, @MainActor app types, no try!/nonconstant unwraps, DIAG-only diagnostics.
Never real tmux/config/defaults; no AFK edits; specified agent identity and lowercase scoped em-dash commits via -F.
**TDD:** extend `cd "$WT/app" && ./Scripts/check-shell-integration.sh` before changing parser.
Remote URL rejection must fail against old parser with exit 1, not a missing-symbol compile failure.
Cases: local live hostname, case variant, localhost, empty host, remote same-path URL, malformed authority, credentials/port.
Keep bare absolute paths and one-time percent decoding, including literal `%2520`, Unicode, malformed/control input.
Implement; gate exits 0; `./Scripts/check-shell-integration.sh --falsify` catches discarded host and double decoding.
Run `./Scripts/check-file-size.sh`; do not silently broaden local aliases to short/FQDN suffix guesses.
**Done:** remote host survives as display-only metadata; existing OSC 133 cases unchanged.
**Return:** standard evidence plus live `$HOST`/hostname compatibility results.

### G — measured asynchronous root/refresh, preserved identity

**Task:** Measure shipped behavior first; then move setRoot/ordinary refresh directory listing off-main.
**Own:** FileNode.swift, FileTreeViewController.swift, +Mutation.swift, +Timing.swift; new DirectoryListing.swift and +Loading.swift.
Also own check-file-tree-ops.sh/harness/cases, new check-tree-refresh.sh/harness, and `.afk/research/tree-refresh-*.md`.
**Forbidden:** E’s +FollowStatus/indicator, +Git, shell/action contracts, AFK.md, user config/defaults; reserve extra tree files explicitly.
**Rules:** 350 wc-LOC ceiling; extract the entire loading concern, never shave; no tests/CI; exit code is verdict.
Temp-copy falsification and reviewer-selected break mandatory; pure listing code Foundation/Darwin only.
Headers/why/evidence comments; all FileNode/AppKit access on MainActor; no try!/runtime unwraps; diagnostics DIAG-only.
No real tmux/config/defaults; no AFK edits; AFK identity and scoped lowercase em-dash commits via -F.
**Measure first:** add a fixture driver without changing production; `GOBLIN_PORTAL_DIAG=1 ./Scripts/check-tree-refresh.sh --baseline`.
Use a large temp tree with expanded directories; optionally read agent-afk/node_modules without mutating that checkout.
Record fixture size, expanded count, samples, median/p95/max, hardware/load, and shipped timing site definitions.
**TDD:** `./Scripts/check-tree-refresh.sh` must fail shipped synchronous implementation with an off-main-listing assertion.
Use a blocked injected listing barrier plus main-run-loop heartbeat, not only a flaky elapsed-time threshold.
Enumerate immutable entry metadata off-main; reconcile FileNode objects only on main preserving URL+flags reuse.
Snapshot loaded descendants on main; enumerate requested paths off-main; never send FileNode/AppKit objects to worker closures.
Invalidate generations on newer root/refresh, mutation/placeholder insertion, edit start, pendingRoot, and teardown.
Completion during inline editing is discarded/deferred and replayed; stale requests cannot erase placeholders.
Extract `reveal` or loading orchestration to free base-controller room; preserve root setter encapsulation.
Keep a named synchronous mutation refresh path so refreshAfterMutation’s walk/rebase/reveal remains ordered.
Keep loadView/disclosure/mutation limitations explicit; do not claim every tree action is now nonblocking.
**Commands:** `./Scripts/check-tree-refresh.sh`; `./Scripts/check-file-tree-ops.sh`; `./Scripts/check-file-ops.sh`.
Then `./Scripts/check-tree-refresh.sh --falsify` and `./Scripts/check-file-tree-ops.sh --falsify`; all wrapper runs require 0.
Mutants: remove generation check, recreate unchanged children, apply during edit, leave late refresh after mutation.
Run `./Scripts/check-file-size.sh`; cases 7,10,12–14 must still pass; remove stdout-based verdict downgrade.
**Done:** measured before/after, deterministic concurrency evidence, preserved stack seam, documented synchronous residue.
**Return:** standard evidence plus identity/generation invariant table and explicit Swift 6 concurrency strategy.

### C — shared local-cwd contract and asynchronous tmux cache

**Task:** Implement ShellContext composition and TerminalPane state; make all currentDirectory readers truthful.
**Own:** ShellContext.swift, ShellDirectoryPolicy.swift, ShellHosting.swift, TerminalPane+DirectoryState.swift;
TerminalPane+ShellIntegration.swift, ShellDirectory.swift, check-cwd-follow.sh, check-shell-context.sh/harness.
**Forbidden:** A/B/D owner files, DirectoryFollow (E owns), tree/actions, AFK.md, resources/vendor.
**Rules:** 350 wc-LOC ceiling; whole-concern extraction; no tests/CI; verdict is harness exit.
New/changed gates require temp-copy falsification plus independently chosen break; pure files Foundation/Darwin only.
Headers explain why; comments cite evidence; app types @MainActor; no try!/nonconstant unwraps; DIAG-only diagnostics.
Never real default socket/config/defaults in gates; no AFK edits; AFK identity, lowercase scoped em-dash commit via -F.
**TDD:** `cd "$WT/app" && ./Scripts/check-shell-context.sh` exits 1 against fail-closed K behavior.
Matrix every foreground kind with stale reported cwd, unavailable kernel cwd, remote host, stale tmux cache.
Test `.command` preserving shell cwd even when command changes cwd; no OSC fallback must also stay shell-owned.
Remote OSC clears/replaces local report provenance; returning local shell cannot reuse a remote path.
Cache completions bind to pane lifetime, current client pid/tty, generation, and current foreground kind.
CurrentDirectory may schedule a refresh, but never waits for tmux; DirectoryFollow explicitly drives refresh too.
Gate actual ShellHosting wiring offscreen, plus pure policy; include ⌘T/split fallback and snapshot nil behavior.
Use isolated defaults/config and loopback fixtures; never read policy truth tables as proof of actual caller wiring.
**Commands:** `./Scripts/check-shell-context.sh`; `./Scripts/check-cwd-follow.sh`; `./Scripts/check-runtime-paths.sh`.
Then `./Scripts/check-shell-context.sh --falsify`; `./Scripts/check-cwd-follow.sh --falsify`; `./Scripts/check-file-size.sh`.
Mutants: stale OSC beats ssh, command kernel cwd beats shell, delayed tmux completion applied after remote transition.
**Done:** all readers audited, direct getter nonblocking, nil persistence intentional, no stale cross-context cache.
**Return:** standard evidence plus consumer-path table and unresolved tmux first-sample latency.

### F — typing-action policy and menu validation

**Task:** Guard all four actions using live foregroundKind and TerminalInputPolicy; beep and explain refusal.
**Own:** AppDelegate.swift, AppDelegate+EditorActions.swift, SpaceViewController+Delegates.swift;
new TerminalActionGuard.swift; check-terminal-actions.sh and split harness; optional AppDelegate+Validation.swift extraction.
**Forbidden:** C’s policy/contracts, tree files, DirectoryFollow, AFK.md, vendor/config/defaults.
**Rules:** 350 wc-LOC ceiling; extract entire validation concern if needed, never shave lines; no tests/CI.
Gate exit is verdict; temp-copy falsification plus independently chosen break mandatory; pure code Foundation/Darwin only.
New headers/why/evidence comments; AppKit types @MainActor; no try!/nonconstant unwraps; DIAG-only diagnostics.
Never real tmux/config/defaults; no AFK edits; AFK identity and lowercase scoped em-dash commit via -F.
**TDD:** `cd "$WT/app" && ./Scripts/check-terminal-actions.sh` fails old action behavior with exit 1.
Drive actual action methods with a capturing ShellHosting fixture and actual menu validation selectors.
Cover shell/knownShell/tmux allowed; command/remote/multiplexer/nil refused for all four actions.
Assert zero bytes on refusal, one short explanation, beep seam invocation, submitted-vs-unsubmitted bytes when allowed.
Recheck inside action even after menu validation passes; test safe→unsafe transition and focused-host fallback.
Do not guard raw send(text:) globally: ordinary user terminal typing remains unaffected.
Use C’s frozen policy rather than introducing a second allowance switch; do not edit ShellContext to unblock yourself.
**Commands:** `./Scripts/check-terminal-actions.sh`; `./Scripts/check-terminal-actions.sh --falsify`.
Also `./Scripts/check-keybindings.sh`; `./Scripts/check-runtime-paths.sh`; `./Scripts/check-file-size.sh`.
Mutants: bypass cd guard, bypass non-submitting guard, validate safe but execute unsafe; build temp copies for GUI mutation.
**Done:** Run greys out unsafe; palette/direct dispatch cannot bypass; tmux outer-client caveat explicitly reported.
**Return:** standard evidence plus all four action byte-capture results and explanation presentation limits.

### E — ambient follow-state indicator and one-writer poller

**Task:** Add a non-modal indicator; drive refresh/status/root from the existing DirectoryFollow timer.
**Own:** SpaceViewController+DirectoryFollow.swift, DirectoryFollowIndicatorView.swift;
FileTreeViewController+FollowStatus.swift, check-directory-indicator.sh/harness.
**Forbidden:** base FileTreeViewController, +Git/+Mutation/+Timing/+Filter, C/A/B/D contracts, action files, AFK.md.
**Rules:** 350 wc-LOC ceiling; whole-concern extraction; no tests/CI; verdict is exit code.
Temp-copy falsification plus independently chosen break required; pure policy files Foundation/Darwin only.
Ownership headers/why/evidence comments; @MainActor app types; no try!/runtime unwraps; DIAG-only diagnostics.
Never real default socket/config/defaults; no AFK edits; AFK identity and lowercase scoped em-dash commits via -F.
**TDD:** `cd "$WT/app" && ./Scripts/check-directory-indicator.sh` fails absent indicator/wiring with exit 1.
On every tick request refresh, obtain one ShellContext, update indicator even if directory/path is unchanged.
Nil cwd retains last local tree; local recovery hides warning; remote/paused/unavailable never call setRoot.
Compare normalized paths rather than URL directory markers for lastPushed; retain single writer followDirectory.
Insert idempotently into the existing stack via associated storage; no edits to G’s files.
Cover key/resign lifecycle, focused split/tab switch, no host, remote→local recovery, SCM mode and narrow accessibility text.
**Commands:** `./Scripts/check-directory-indicator.sh`; `./Scripts/check-directory-indicator.sh --falsify`.
Also `./Scripts/check-sidebar-activity.sh`; `./Scripts/check-file-size.sh`.
Mutants: never update status when cwd nil, keep indicator after recovery, duplicate installation on repeated ticks.
**Done:** behavioral installation/state gated; rendering remains explicitly manual.
**Return:** standard evidence plus checklist rows for themes/fullscreen/SCM/VoiceOver and pending visual checks.

### H — docs, integration evidence, and follow-up draft

**Task:** Consolidate capability limits, gate instructions, manual checklist, and follow-up issue draft.
**Own:** app/README.md, `.afk/verification/tmux-ssh-cwd-checklist.md`, `.afk/research/cwd-follow-integration.md`;
`.afk/research/tmux-shell-integration-follow-up.md`.
**Forbidden:** all Sources/Scripts, AFK.md, vendor/resources; no issue creation/push/PR mutation.
**Rules:** 350 ceiling remains on Sources/Scripts; no tests/CI; gate verdicts are exits, not prose.
All changed gates need temp-copy falsification and independent breaks; pure code Foundation/Darwin only.
Headers/why/evidence comments; app types @MainActor; no try!/runtime unwraps; DIAG-only diagnostics.
No real sockets/config/defaults; no AFK edits; AFK identity, lowercase scoped em-dash commit via -F.
**Evidence-first docs:** draft from lane receipts; missing evidence stays unchecked, never retrospectively invented.
List new files/LOC and changed rows for coordinator; coordinator updates AFK table/Commands/Known Risks.
Run `cd "$WT/app" && ./Scripts/check-file-size.sh`; after coordinator AFK update run `./Scripts/check-afk-loc.sh`.
No documentation-only fake TDD requirement: H changes no executable behavior or gate; validate commands against V receipts.
Follow-up draft: opt-in DCS passthrough/patch 0005, pane attribution ambiguity, zellij/screen, bash/fish.
**Done:** distinguish local cwd, remote status, tmux typing limitation, async scope, environmental and manual residue.
**Return:** changed docs, exact AFK row replacements, commands/exits, draft issue path, commit SHAs.

## 8. Fan-in strategy and conflict matrix

Coordinator merges only completed, reviewed lane commits into `afk/add-tmux-ssh-cwd`; never main.
Preserve managed child worktrees until their commits are integrated and receipts reconciled.
Merge K first, then A/D/B in completion order; G can merge whenever its dedicated tree gates pass.
Launch C from integrated A+B+D; launch F from A+K; E from completed C.
Use explicit branch/commit manifests; do not merge a branch merely because its name matches a glob.

| Pair | Text overlap | Semantic coupling | Treatment |
|---|---|---|---|
| A/B/D/G | none after K ownership transfer | API contracts | safe parallel |
| C/F | none | ShellHosting + input policy | frozen API, integrated adversarial review |
| E/G | none by enforced forbidden list | root stack/layout | preserve NSStackView; combined GUI gate |
| C/E | none | context refresh/status | E starts after C |
| K/A,B,D,C | intentional same files | stub replacement | sequential, no parallel merge ambiguity |
| H/all | docs only | evidence accuracy | H after feature fan-in |
| AFK/all | coordinator-only | LOC bookkeeping | refresh rows after each merge |

Before every merge run a read-only merge-tree conflict preview; unexpected owned-file overlap is a stop.
Never “resolve” unexpected overlap by taking one side wholesale; return to the owning lane.
After **each merge** run check-file-size and coordinator-updated check-afk-loc.
Additional merge gates: A→foreground+cwd; D→shell-integration; B→tmux; G→tree-refresh+file-tree-ops.
C→shell-context+cwd+runtime-paths; F→terminal-actions; E→indicator+sidebar-activity.
Run `swift build` after each feature merge; GUI gates use their freshly built swiftbuild backend.
Final ordering: K → A/D/B → C → F → E, with G inserted independently before H/V.
A gate exit 1 stops fan-in; exit 2 is BLOCKED, not passing; record existing verify-vendor exit 3 separately.
No push or PR publication until the final verdict and manual residual status are explicit.

## 9. Independent review and final verification wave

R-CF / Anthropic sonnet: read integrated C/F cold, not implementation rationale.
Trace all four action paths, actual selectors, live foreground recheck, host fallback, nil behavior, OSC provenance.
Challenge tmux cache identity, command-vs-shell cwd, reader/persistence fallback, and provider/API assumptions.
Return blocking findings with path:line and one unforeseen temp mutant that must exit 1.

R-G / Anthropic opus: independently trace every FileNode write and worker capture.
Challenge A→B→A root races, mutation during refresh, edit-start races, placeholder survival, cancellation, teardown.
Verify identity+flags, loaded descendants, expansion/selection restoration, and retained synchronous paths.
Return path:line findings, deterministic reproduction recipe, and an unforeseen temp mutant.
Neither reviewer edits code; repairs go to original owner with 80–100 rounds and a fresh verification pass.

V runs sequentially in the fully integrated worktree and records command/exit/duration/log fingerprint:
`cd "$WT/app" && swift build`
`./Scripts/check-file-size.sh`
`./Scripts/check-afk-loc.sh`
`./Scripts/check-cwd-follow.sh`
`./Scripts/check-shell-integration.sh`
`./Scripts/check-file-tree-ops.sh`
`./Scripts/check-file-ops.sh`
`./Scripts/check-sidebar-activity.sh`
`./Scripts/check-runtime-paths.sh`
`./Scripts/check-space-restore.sh`
`./Scripts/check-keybindings.sh`
`./Scripts/verify-vendor.sh`
`./Scripts/check-shell-contracts.sh`
`./Scripts/check-foreground-process.sh`
`./Scripts/check-tmux-directory.sh`
`./Scripts/check-shell-context.sh`
`./Scripts/check-terminal-actions.sh`
`./Scripts/check-tree-refresh.sh`
`./Scripts/check-directory-indicator.sh`
`./Scripts/make-app-bundle.sh`

Also enumerate and run every remaining shipped `Scripts/check-*.sh` gate once on the final SHA.
Do not run that wildcard blindly: audit isolation and environmental needs first.
GUI/Metal/display-scale/Accessibility gates may be blocked; record exact unmet prerequisites.
Existing falsification paths that mutate vendor/resources must run on an isolated package copy, never the integrated originals.
Use monitored long commands and success **and failure** signatures; never infer success from silence.
Repeat all new/changed gate `--falsify` commands plus reviewer-provided mutants.
Record ordinary `swift build` separately from swiftbuild-based object-linked gates to prevent stale-object evidence.

False-completion reconciliation is against **commits and fresh reads**, not child assertions:
- Pin final HEAD and full SHAs for every lane; verify each is an ancestor of integration HEAD.
- Enumerate committed paths versus lane ownership and declared deliverables.
- Read back contract bodies: no deny/nil scaffolding remains masquerading as implemented behavior.
- Recompute LOC, AFK rows, gate hashes, and artifact paths from the integrated commit.
- Confirm baseline predates G’s implementation and red/green/mutant exits exist in persisted transcripts.
- Confirm bundle binary/resources correspond to the tested integrated state.
- Confirm no original-file mutation residue, default-socket commands, real config/defaults writes, or dirty source state.
- Verdict: VERIFIED, BLOCKED-ENVIRONMENT, MANUAL-PENDING, or FAILED; never collapse these into “done.”

## 10. Manual residue, risks, and abort conditions

Manual checklist: real ssh session with/without remote OSC 7; return to local shell; failed ssh connection.
Check same-named remote/local paths, local hostname compatibility, stale path never inherited by ⌘T/splits.
Render indicator under dark/light themes, narrow sidebar, fullscreen, SCM switch, split focus, VoiceOver.
Observe real tmux custom socket, active split/window switching, agent REPL refusal outside tmux.
Explicitly demonstrate/document the tmux-active-pane safety limitation rather than hiding it.
For live app probes use isolated config home **and verified isolated defaults domain/bundle identity**.
Do not assume setting HOME alone isolates Goblin Portal; audit the launch/config path first.
A human-driven large-tree DIAG measurement is optional corroboration, not a blocker for deterministic baseline fixtures.

Abort on: runtime force unwrap/try!, any >350 wc-LOC file, unapproved contract drift, real-state writes.
Abort on: worker reading/mutating FileNode/AppKit, unbounded subprocess cleanup, stale completion application.
Abort on: TDD/falsification “red” being only compile failure, stdout forgiveness, unchanged gate passing a mutant.
Pause on missing tmux/toolchain/window server; report environment, never weaken assertions to obtain green.
Escalate if Swift 6 requires Sendable annotations or unsafe isolation beyond the approved convention.
Escalate if preserving mutation ordering requires broader async mutation redesign; keep the scoped synchronous path instead.
External follow-up issue creation and PR publication remain coordinator actions after authorization/context verification.

**Boundary flag:** low-coverage — this planning session read the named code/gates and verified git state, but did not execute runtime probes.