# Goblin Portal

A native macOS terminal, in Swift, with no AI features. Built to host
[`agent-afk`](https://github.com/griffinwork40/agent-afk) well.

Renamed from **Umber** to **Goblin Portal** on 2026-09-15. The theme preset
`"umber"` (a warm earth pigment) survives as an easter egg. See
[`../.afk/research/naming-decision-2026-07-27.md`](../.afk/research/naming-decision-2026-07-27.md)
for the original naming rationale.

Step 2 of [`../.afk/plans/native-swift-terminal-afk-host.md`](../.afk/plans/native-swift-terminal-afk-host.md).

## Build and run

```sh
./Scripts/make-app-bundle.sh          # debug
./Scripts/make-app-bundle.sh release  # optimised
open build/GoblinPortal.app
```

Or, for a quick iteration loop without bundling:

```sh
swift run GoblinPortal
```

The bundle path is what you want for real use — it gets a Dock icon, appears in
Spotlight, and behaves like an app rather than a stray process.

## Checks

There is no test target: this app is mostly AppKit glue, and what has actually
broken here is *observable state* — the font that silently fell back to Menlo, the
collapsed scrollbar thumb, the key that wrote no bytes — none of which a unit test
of pure logic would have caught. So the checks are ten `check-*.sh` scripts, a vendor
verifier, and a diagnostic env var, each aimed at something that has really gone wrong:

```sh
./Scripts/verify-vendor.sh       # is vendor/SwiftTerm the pinned revision, WITH all six patches?
./Scripts/check-file-size.sh     # enforces the 350-LOC ceiling on Sources/ + Scripts/ — headless
./Scripts/check-keybindings.sh   # truth table for the ⌘ line-editing map — fast, headless
./Scripts/check-space-restore.sh # truth table for OpenSpaceRoots (Space restore) — fast, headless
./Scripts/check-cwd-follow.sh    # does the sidebar follow the shell's cwd? — fast, headless
./Scripts/check-shell-integration.sh # OSC 133 A/C/D state machine + parseOsc7Directory URL parsing — fast, headless
./Scripts/check-git-status.sh    # porcelain-v2 parsing + repo discovery, on real repos — headless
./Scripts/check-reflow.sh        # does narrowing corrupt scrollback? (#494) — headless
./Scripts/check-altbuffer-resize.sh # does an alt-buffer resize resurrect stale cells? — headless
./Scripts/check-metal-renderer.sh # does the GPU renderer actually ship AND come up? — offscreen GUI
./Scripts/check-renderer-config.sh # does a `renderer` string reach the renderer it names? — fast, headless
./Scripts/check-engine-config.sh  # does an `engine` string reach the emulator core it names? — fast, headless
./Scripts/check-light-theme.sh   # are the palettes well-formed, and is `afk-light` light enough to flip the chrome? — fast, headless
./Scripts/check-pane-teardown.sh  # does closing a document free its surface and kill its shell? — offscreen GUI
./Scripts/check-find-menu.sh     # do Undo/Redo/Find-and-Replace actually reach anything?
                                 # needs a GUI session; window is offscreen, steals no focus
./Scripts/check-sidebar-toggle.sh # is the titlebar toggle installed, does its action resolve,
                                 # and does clicking it move the sidebar? offscreen, steals no focus
./Scripts/check-keys-e2e.sh      # real NSEvents → real pty bytes; opens a window,
                                 # needs Accessibility permission for your terminal
GOBLIN_PORTAL_DIAG=1 swift run GoblinPortal   # dumps resolved font/theme/scrollback state to stderr
```

`verify-vendor.sh` runs first inside `make-app-bundle.sh`, and exists because the two
vendor failure modes were asymmetric. A **missing** `vendor/` fails loudly — SwiftPM
cannot resolve the path dependency. A **re-vendored but unpatched** tree failed
*silently*: it compiled and ran, because patch 0001 only drops a build-time resource, so
following the recreation steps below and forgetting the patch produced a green build
against a different dependency than the tested one. Nothing in git recorded otherwise —
`vendor/` is gitignored, `vendor/SwiftTerm` is not a git repo, and `Package.swift`'s path
dependency is unpinned. `Package.resolved` **is** committed as of the libghostty pin, but
it changes nothing here: SwiftPM writes no pin entry for a local path dependency, so that
file records the three remote packages and stays silent about the vendored one. Exit
codes: `2` = present but unpatched, `3` = unknown revision, `1` = missing vendor or
missing pin.

It checks **two** files now, and both are hard failures. `Buffer.swift` was a warn-only
version tripwire until 2026-07-29, when patch `0002` made it load-bearing: a tree missing
that patch compiles, runs, passes every other check, and silently corrupts scrollback on
every window narrowing. Warn-only would have meant the single check able to catch that
printing to stderr and exiting `0` — the exact silent-failure asymmetry this script exists
to kill. `check-reflow.sh` is the behavioural half of the same guarantee: it fails 6 of its
8 cases against an unpatched tree, so the patch cannot be quietly lost.

`check-space-restore.sh` follows `check-keybindings.sh`'s pattern — compile the shipped
source, run a truth table — and is the exception that proves the rule above rather than a
contradiction of it. Restoring Spaces only *pays off* across a quit/relaunch boundary, and
that half (real window tab grouping) is genuinely not verifiable headlessly. But the half
that decides **what** comes back is ordinary logic over (stored strings, what exists on
disk), including the fail-soft cases whose only other discovery path is a user whose app
opens to nothing. It runs against a temp directory and a bundle-less binary's own defaults
domain, so it cannot disturb your real remembered Spaces — and asserts that isolation as
its last case instead of trusting it.

`check-cwd-follow.sh` follows the same pattern for the sidebar-follows-shell feature, and is
the most explicit of these gates about its own blindness. It compiles the shipped
`ShellDirectory.swift` standalone — that file imports only Foundation and Darwin precisely so
it can — spawns a real child shell into a temp directory, and reads that directory back
through the same two syscalls the app uses, then checks the `cd` line it builds against paths
containing spaces, quotes and `$`. Two things it cannot reach are named in its own comments
rather than papered over. The `tcgetpgrp` branch is one: Darwin needs an explicit `TIOCSCTTY`
that a `posix_spawn`ed child cannot issue and Swift marks `fork()` unavailable, so that branch
only executes for real inside SwiftTerm's `forkpty` (`LocalProcess.swift:513`) — the gate
asserts the `proc_pidinfo` fallback it *does* exercise and says so, instead of letting a case
titled "foreground" quietly test something else. `setRoot(_:)` is the other, being AppKit.
It paid for itself before it first went green: it caught the `URL`-vs-`.path` equality trap now
documented at `FileTreeViewController.setRoot(_:)`, where `URL` equality carries a directory
marker that `resolvingSymlinksInPath()` drops on a symlink-terminated path — which would have
rebuilt the file tree twice a second and destroyed the user's expansion state.

`check-git-status.sh` gates the git sidebar's data layer, and it is the only check here made of
**two files**: the shell half builds fixtures, and the assertions live in
`Scripts/check-git-status-harness.swift`, which it copies to `main.swift` and compiles against
the two shipped sources. That split was forced by the 350-line ceiling rather than chosen —
inline the halves came to 358 lines — but it lands on a real seam, and the harness being actual
Swift rather than a quoted heredoc means a formatter and an editor can both read it.

Every fixture is built by running real `git`: real commits, a real `git mv` (so the `-z` rename
record really does span two NUL-delimited tokens), a real merge conflict from two diverging
branches (so the `u` record's different field count is really exercised), a real bare remote,
a real detached HEAD, and a real `git worktree add` — the last because in a worktree `.git` is
an ASCII *file*, not a directory, so any repo detection written as `isDirectory(root/.git)`
would fail on every `.afk-worktrees/*` checkout including this project's own while passing
every manual test from an ordinary clone. Hand-typed porcelain strings were refused for the
reason `check-cwd-follow.sh` gives about quoting: they encode only the author's assumptions
about the format, which is exactly where a looks-right-is-wrong bug hides.

It was validated by falsification like the reflow pair, but the counterexample had to be
manufactured — there is no upstream bug to revert in first-party code. A deliberately naive
parser was written first (rename token not consumed, `u` record read with the ordinary field
offsets, fixed fields whitespace-split), the finished gate was run against it, and it failed
4 cases while the **control case stayed green** — which is the part that matters, because a
harness bug would have shown up as control-and-edges-both-red and its verdict would have had
to be thrown away. The transcript is kept at
`.afk/research/git-sidebar-falsification-2026-07-31.md`.

What it cannot reach is stated in its own header: the poller's cadence, the badge glyph, colour
legibility inside the selection pill, and every line of AppKit wiring — all of which import
AppKit and therefore cannot be compiled alone. `GOBLIN_PORTAL_DIAG=1` prints one `[goblin-portal] git:` line
per changed snapshot to cover the gap that matters most, which is telling "not a repository"
apart from "the tint failed to draw".

`check-reflow.sh` is the gate for SwiftTerm #494 and for local patch `0002`. It compiles a
harness against the **vendored emulator itself** (not a file from `Sources/GoblinPortal`), seeds
more lines than `rows` so the scrollback offset `_yBase` is non-zero, uses absolute CUP to
put the cursor above the last row — the only state in which the faulty branch at
`Buffer.swift:1167`/`:1205` executes at all — writes a wrapping line, narrows, then asserts
over the **whole normal buffer including scrollback** via `getBufferAsData`
(`Terminal.swift:5947`, whose loop is `for row in 0..<b.lines.count` at `:5953`). It exists
because the *previous* reflow gate was blind three ways, and each is inverted deliberately:
it never produced `_yBase > 0` together with the faulty branch; it read back with
`getLine(row:)`, which returns nil for `row >= rows` (`Terminal.swift:759`) and so can only
see the visible screen, never the scrollback where the corruption lands; and it asserted
only that tokens were not duplicated, never that they were not missing. All of missing,
duplicated, reordered, interior-blank-row and merged-row are asserted here. Exit codes are
split so an environment problem cannot read as a pass: `1` = real assertion failure,
`2` = environment (no `vendor/`, no toolchain, harness would not compile, or a case's own
scrollback-capacity precondition failed).

The load-bearing assertion is the **interior blank row**, not the token counts: the
observed corruption keeps every token exactly once and still wrecks history, splicing a
blank row into the middle of scrollback and shifting everything below it. Token counts
alone would have been another green-but-blind gate. Missing tokens *are* asserted, but only
because every case sizes scrollback with headroom and the harness checks that headroom as a
precondition — a token vanishing is unambiguous corruption only when legitimate trimming is
impossible, which is the confound the old gate cited as its reason for dropping the
assertion entirely.

`check-altbuffer-resize.sh` is the gate for local patch `0003`, and it is `check-reflow.sh`'s
sibling: same vendored subject, same `SwiftTerm.o` link, same `1` vs `2` exit split. It exists
because `check-reflow.sh` going green said **nothing** about the alternate buffer — it only
ever exercised the normal one, and the alt buffer is precisely where the second `Buffer.swift`
defect lived, so "the reflow gate is green" was a narrower claim than it looked like. Each of
its four cases answers a different question. Case 1 observes the defect directly: after
narrowing, are the alt buffer's lines still their old width? Case 2 is the user-visible bug
end to end — narrow, let tmux fully repaint at the new width, widen again, and assert that
nothing from the wide era reappears. Case 4 asserts the stale cells are *not* visible while
narrow, which is what makes "the corruption shows up when you make the window bigger" a
prediction of the model rather than a coincidence, since the renderer clamps to
`min(terminal.cols-1, line.count-1)` (`Apple/AppleTerminalView.swift:887`).

Case 3 is the one worth copying elsewhere. It runs the **identical** sequence against the
normal buffer, where the trim always ran, and asserts it stays clean. Without it, a harness
bug that broke every case would read as a damning result for the code under test; with it,
cases 1–2 failing *while the control passes* is the only shape that implicates the alt-buffer
path specifically. The gate was then validated the same way `check-reflow.sh` was — by
falsification, not by passing: reverting `0003` fails exactly cases 1 and 2 and keeps 3 and 4
green. A gate that has never been observed to fail for the right reason is not evidence.

`check-metal-renderer.sh` is the gate for local patch `0001` and for SwiftTerm's
`setUseMetal`/`isUsingMetalRenderer` contract — the `renderer` config *string*, and whether it
maps to the case it names, is `check-renderer-config.sh`'s job below — and it guards a failure
that is invisible by construction: a config that says
`"renderer": "metal"` while the app quietly draws with Core Text. That is not hypothetical —
it was this project's actual state until 2026-07-31, because `0001` used to `exclude:` the
Metal shader rather than ship it, and `MetalTerminalRenderer` needs the `.metal` source in the
resource bundle so it can compile it at runtime. Six cases: two static (the shader is in the
SwiftPM resource bundle, **and** in `GoblinPortal.app/Contents/Resources` — different lookup paths,
so one proves nothing about the other), three behavioural (asking for `metal` yields metal;
asking for `coretext` yields coretext; and asking for `metal` *then* `coretext` in one process
still yields coretext), and one falsification. Only the third behavioural case is a real
control. A freshly built view already has `useMetalRenderer == false`, so `setUseMetal(false)`
on its own early-returns (`Mac/MacTerminalView.swift:379-381`) and the case passes without any
teardown running — it would still pass if `setUseMetal` were a no-op. The metal-then-coretext
case is the one that removes the `MTKView` and restores the caret view, which is what a ⌘R
after editing `renderer` back to `coretext` actually does. The falsification case is the
load-bearing one: it hides
`Shaders.metal`, re-runs, and *requires* the request to fail. If Metal still came up with the
shader hidden, the gate would be passing for some reason other than our packaging and its
other cases would mean nothing — so that case exits `1` saying the gate is BLIND rather than
reporting success. Like the two gates above it separates `1` (a real failure) from `2` (no
Metal device, no window server, build broken) — and a harness process that dies is `2`, not a
wrong-renderer `1`, because a crash is a statement about the machine.

`check-renderer-config.sh` is that gate's necessary sibling, and the reason it is a separate
script is the reason it is worth having. Every behavioural case above calls SwiftTerm's
`setUseMetal` directly, which means all of them bypass `Renderer.named` — the hand-maintained
table that turns a string in `config.json` into a case. So a typo there would ship with
`check-metal-renderer.sh` still green, and the symptom would be the quietest one available: a
config line that reads correctly, parses without a warning, and does nothing. That is the same
class of silent failure patch `0001` caused for the life of the project. It compiles the
shipped `Renderer.swift` standalone — that file is Foundation-only *by design*, the same trick
`check-keybindings.sh` plays on `KeyBindings.swift` and `check-cwd-follow.sh` plays on
`ShellDirectory.swift` — and so needs swiftc and one source file, no GPU, no window server, no
`swift build`. Folding it into the expensive gate would have made the cheap half unavailable on
exactly the machines where the other half cannot run. It asserts all thirteen accepted
spellings, that unknown values and a trailing space map to `nil` (which is what lets
`AppConfig.load()` warn and degrade instead of silently switching renderer), that `configName`
round-trips for every case — driven off `allCases`, so adding a case cannot leave the assertion
behind — and that the default is still `coretext`. It was validated by falsification like its
siblings: breaking one alias, flipping the default, and making unknown values resolve each make
it fail with the specific case named.

`check-find-menu.sh` covers the three Edit-menu items with **no Goblin Portal code behind them** —
Undo, Redo, and Find and Replace are AppKit responder actions reached with `target = nil`,
so all three are correct only as long as an assumption about the SDK holds. It checks that
`undo:`/`redo:` are answered by NSWindow (not NSTextView, which does not implement them),
that the find tags are still the `NSFindPanelAction` raw values the menu reads off the SDK,
and — behaviourally, against a real offscreen `NSTextView` — that tag 12
(`NSTextFinder.Action.showReplaceInterface`, which `NSFindPanelAction` has no case for)
genuinely produces the replace row. That last one is why the script exists: a menu item
wired to an unanswered selector or an unrecognised tag renders, highlights, clicks, and
does nothing, and nothing else in this repo would notice. It sends each tag in its own
process, because sharing one text view let the bar keep the previous action's state and a
dead tag passed; and it distinguishes "no window server" (exit 2) from "tag 1 worked but
tag 12 did nothing" (exit 1), so a real dead item cannot hide behind an environment excuse.

`check-sidebar-toggle.sh` is that script's sibling one level down. The titlebar's sidebar
button is the same construct — `target = nil`, action answered only by the responder chain —
except a button in the titlebar is *less* conspicuous than a menu item, so a dead one would
survive longer. Against a real offscreen `SpaceWindowController` it asserts that exactly one
accessory is installed, that the button's shape is intact (nil target, `toggleSidebar:`, an
accessibility label and a tooltip, an image), that **the button's own action** resolves to a
live responder, that `isCollapsed` flips in both directions, and — as a control — that a
bogus selector resolves to nil, so a run cannot be green because the rig answers everything.

Two of those assertions had to be repaired before the gate was worth anything, and how they
were found is the useful part. The first falsification deleted the
`addTitlebarAccessoryViewController` call, which fails case 1 and stops there — it proved
only the case already in mind. Breaking it differently, by pointing `button.action` at a
nonsense selector, showed case 3 resolving a hardcoded selector instead of the button's own
(green while the shipped button was inert) and case 4's back-flip test passing trivially
whenever the first click had not moved anything, printing "FLIPPED IT BACK (false -> false)".
Both are fixed and the same break now fails four cases. Falsify with a break the author did
not already have in mind; the one they pick tends to exercise the assertion they trusted most.

## What works today (v0.1)

- Real `.app` bundle, ad-hoc signed
- Your login shell (`$SHELL -l`, so your real `PATH` and rc files load)
- **Spaces and documents — two tab levels.** A **Space** is a project root and is
  a real native macOS window tab (⌘N), so ⌘⇧[ / ⌘⇧] cycling, the tab overview,
  drag-to-reorder, drag-out-to-detach and Merge All Windows all work without being
  implemented. **Documents** live in a hand-rolled strip inside a Space (⌘T,
  ⌘⌥←/⌘⌥→, ⌘1–⌘9), because a system window tab *is* an `NSWindow` and could
  therefore never share one sidebar across a mixed terminal/editor strip. The strip
  hides itself at a single document. See plan §12.3.
- **Every open Space reopens on relaunch**, as one native tab group, each rooted where
  it was — *not* its documents, because a shell has no resumable state and four fresh
  prompts dressed up as your last session would be theatre. Window geometry is
  remembered per project root. First launch, or every remembered root having been
  deleted, gives you one Space at `$HOME`.
- **Sidebar file tree** (⌘B) — lazy `NSOutlineView` rooted at the Space, Finder
  icons, dotfiles shown (`.git`/`.DS_Store` excluded), refreshed when the window
  becomes key. Double-clicking a file types its quoted path into the focused
  terminal — the pre-editor affordance; when an editor document kind exists it will
  open in a tab instead.
- Config file with live reload (⌘R), full screen (⌘F)
- **Font sizing that sticks** — ⌘+ / ⌘- zoom every tab at once and the level
  survives new tabs and relaunches; ⌘0 clears the zoom and hands control back
  to `font.size`. Default is 14pt
- **Mac line-editing keys** — ⌘⌫ deletes to the start of the line, ⌘⌦ to the
  end, ⌘←/⌘→ jump to the ends of the line. macOS resolves these to text-view
  selectors (`deleteToBeginningOfLine:`, …) that SwiftTerm drops, so ⌘⌫ used to
  write nothing at all and ⌘←/⌘→ moved by *word* — already ⌥←/⌥→'s job. They now
  send the readline bytes (`^U ^K ^A ^E`) that bash, zsh, fish and afk's own REPL
  all bind to those operations
- Copy/paste/select-all, window position restored across launches
- **Umber palette by default.** Installing a theme is safe for the 256-colour cube,
  though the code comments said otherwise for months: SwiftTerm *would* regenerate
  indices 16–255 by interpolating bg/fg (`.base16Lab`), but
  `TerminalPane.apply(config:)` sets `ansi256PaletteStrategy = .xterm` first, so a
  theme moves 0–15 and the standard cube stays. `classic-repaired` preserves
  Terminal.app Basic's true black, quiet body text and saturation while repairing
  its unreadable blue; the other presets remain one config line away

## Not built yet

Splits. A real app icon. Preferences UI (config is a JSON file). Shell
integration (OSC 7/133). Search. URL clicking. Profiles.

## Configuration

Lives at `~/.config/goblin-portal/config.json`. It does not exist until you create
it — **Settings… (⌘,) writes a commented starter file** and opens it. ⌘R reloads
without restarting.

Every field is optional and every field fails **soft**: a bad value degrades to
the default and prints a reason to stderr rather than crashing or silently doing
nothing. Verified — a config with six bad fields yields six warnings and a
working terminal.

```json
{
  "font": { "family": "SF Mono", "size": 16 },
  "cursor": "block",
  "scrollback": 1000,
  "optionAsMeta": true,
  "renderer": "coretext",
  "theme": { "preset": "umber" }
}
```

Omit `theme` entirely and you get **umber**, the built-in default since 2026-08-03. `"preset": "classic"` is now the only way to install no colours at all.

`"preset": "umber"` is the palette designed *for* this app rather than ported into it, and the
only one here whose claims are measured: a warm umber-black base (every widely-used dark theme
measured sits cold, hue 219–291°, or at zero chroma), dim text that is actually legible (APCA
Lc 51.5, against 0.0–34.3 for the nine reference palettes — Solarized Dark's is literally
invisible), bright colours genuinely distinguishable from their normal counterparts (Tokyo
Night, Catppuccin, Nord and Rosé Pine all ship *identical* values there, so bold text is
indistinguishable from plain), and red/green that stays separable for a red-green colour-blind
reader. `./Scripts/check-theme-contrast.sh` is the gate; the derivation, the measurement
tooling, and four documented wrong answers are in `.afk/research/theme-design-2026-08-03/`.

| Field | Notes |
|---|---|
| `font.family` | Any installed monospaced family. Omitted, or set to `SF Mono`/`system`, gives the system monospaced face (SF Mono) — the default. An unavailable family warns and falls back to it. Note `NSFont(name: "SF Mono")` returns nil, so SF Mono is only reachable via that alias, never by name |
| `font.size` | Points, **6–48**, default **14**. Out of range warns and uses the default rather than silently clamping. ⌘+ / ⌘- zoom on top of this and persist; ⌘0 clears the zoom so this value applies again |
| `cursor` | `block`, `steady-block`, `bar`, `steady-bar`, `underline`, `steady-underline` |
| `scrollback` | Lines retained, default `1000`. `0` disables it. Raising it is not free: SwiftTerm sizes the scrollbar thumb as `max(rows / lines, 0.01)`, so past ~3,500 lines the thumb sticks at the 1% floor and stops tracking position, and `Buffer.resize` walks every line twice on each window resize (three times until local patch `0004` removed an ungated upstream debug assertion) |
| `shell` | Defaults to `$SHELL`. Must be executable or it is ignored |
| `optionAsMeta` | `true` makes Option act as Meta instead of typing accented characters |
| `renderer` | `coretext` (default) or `metal`. `metal` selects SwiftTerm's GPU path — a CoreText glyph atlas plus GPU quads, whose `.perRowPersistent` buffering caches per-row vertex data and rebuilds only dirty rows. The Core Text path has no such cache on macOS: it rebuilds an attributed string and a `CTLine` for every visible row on every frame. **Opt-in**, because upstream labels the GPU path experimental and its speedup here is not yet measured. It falls back to `coretext` on its own if it cannot initialise and prints one line to stderr saying so — run `./Scripts/check-metal-renderer.sh` if you suspect a silent fallback. Accepted spellings, case-insensitive with `_` read as `-`: `coretext`/`core-text`/`cpu`/`cg`/`coregraphics`/`core-graphics`, and `metal`/`gpu`. Anything else is rejected with a warning naming the valid values rather than silently ignored — `./Scripts/check-renderer-config.sh` is the gate for that mapping |
| `engine` | `swiftterm` (default) or `ghostty`. Which terminal core backs a **new** tab. `swiftterm` is the vendored SwiftTerm this app was built on; `ghostty` is libghostty, which is actively maintained and supplies shell integration SwiftTerm structurally cannot — OSC 7 (the shell reports its working directory, so the sidebar follows it without polling the kernel) and OSC 133 (command boundaries and exit status). **Read once, when a tab is created.** Edit it, hit ⌘R, and the next ⌘T uses the new core while the tab in front of you keeps its own — swapping a core under a live shell would discard its scrollback and its process. That is deliberate: it means both cores can run side by side in one window, which is the only honest way to compare them on the same work. **Opt-in**, because the one bug class that matters most here — buffer reflow when a window is narrowed — is gated for SwiftTerm (`check-reflow.sh`) and not yet for libghostty. `renderer` above applies to `swiftterm` only; libghostty draws with its own renderer and ignores it. Accepted spellings, case-insensitive with `_` read as `-`: `swiftterm`/`swift-term`/`swift`/`legacy`, and `ghostty`/`libghostty`/`lib-ghostty`. Anything else is rejected with a warning naming the valid values — `./Scripts/check-engine-config.sh` is the gate for that mapping |
| `theme` | **Defaults to `umber`** (changed 2026-08-03; it was previously "install nothing", which measured as the worst palette in the repo — its ANSI 4 blue sat at APCA Lc 16.9, 2.9 points from the `#0000EE` the gate exists to reject). Installing a palette is safe for the 256-colour cube: `TerminalPane.apply(config:)` pins `ansi256PaletteStrategy` to `.xterm` before any colour, so indices 16–255 keep the standard xterm values whatever you set. (Earlier docs here claimed the opposite — that installing a background regenerates 16–255 by interpolating your bg/fg. That describes SwiftTerm's *library default*, which this app has overridden for some time; corrected 2026-08-03.) |
| `theme.preset` | `umber`, **`classic-repaired`**, `afk-dark`, **`afk-light`**, `tokyo-night`, or `classic`. `classic-repaired` keeps classic's true black, quiet body text and saturated ANSI colours while repairing its unreadable blue and collapsed blue/white bright steps; `classic` still means "install nothing". Its 11pt document chrome deliberately uses ANSI white rather than the quiet terminal foreground, and the contrast gate measures that actual seam. `afk-light` is the only light palette. Other fields override the preset; supplying colours without one bases them on `umber`. Unknown names warn and fall back to `umber`. The two theme gates pin the palette/name and light/dark chrome contracts |
| `theme.ansi` | **Exactly 16** colours, 8 normal then 8 bright. SwiftTerm's `installColors` silently no-ops on any other length, so a wrong count is rejected with a warning instead |

Classic's repaired alternative and both former defaults are presets — no hex-pasting required:

```json
"theme": { "preset": "classic-repaired" }
```

This keeps Basic's true-black, high-chroma character and quiet `#8A8A8A` body text,
raises blue from APCA Lc 16.9 to 45.1, and restores distinguishable blue and white
normal/bright pairs. The rest of the chromatic ring is unchanged from SwiftTerm.


```json
"theme": { "preset": "tokyo-night" }
```

`tokyo-night` was the v0.1 default, `afk-dark` briefly replaced it. Either
installs a full 16-colour palette; neither disturbs indices 16–255.

### Light mode

```json
"theme": { "preset": "afk-light" }
```

`afk-light` is **GitHub Light Default**, copied verbatim from primer's published
`terminal.ansi*` keys — the exact mirror of `afk-dark`, which is a GitHub *Dark*
skeleton. It was chosen over Solarized Light, Catppuccin Latte and Tokyo Night
Day by measurement: of the twelve ANSI slots a TUI actually colours text with,
the number falling below WCAG contrast 3.0 on that scheme's own background is 5,
7 and 3 respectively — and **0** for this one. Its foreground is CR 15.80.

Setting it also flips the **window chrome** — sidebar, titlebar, scrollers — to
light, with no second setting to change. That is not new machinery: appearance
has always been derived from the theme background's luminance
(`AppConfig.appearance`), which is the same rule Ghostty calls `window-theme =
auto`. `./Scripts/check-light-theme.sh` asserts the derivation holds for this
preset, because a light theme that landed below the cutoff would install its
colours and leave the sidebar dark — parsing, warning about nothing, and
half-working.

**Known limitation, and it is a real one.** Only ANSI 0–15 are the theme's.
Indices 16–255 are the fixed xterm cube (see the note above), which was designed
for a dark background and does not adapt: measured against `#FFFFFF`, **144 of
those 240 colours** fall below CR 3.0, including the top of the greyscale ramp.
Programs that reach for 256-colour output — `bat`, `delta`, `ls` with a rich
`LS_COLORS`, most TUI dashboards — will have washed-out patches on a light
background, and no palette choice here can fix that, because the cube is the
emulator's rather than ours. Changing it would alter 256-colour rendering for
existing dark users too, so it is deliberately not done.

## Dependency note

Depends on `../vendor/SwiftTerm` — upstream **v1.15.0** with **six** local patches:

1. `0001-ship-metal-shader-as-copy-resource.patch` — declares the Metal GPU renderer's
   shader as a **`.copy`** resource where upstream has `.process`. `.process` invokes the
   offline Metal compiler at build time, which cannot work here (Xcode 26.6 moved the
   toolchain to `xcodebuild -downloadComponent MetalToolchain`, and this machine has Command
   Line Tools only — the build dies at `unable to spawn process 'metal'`). `.copy` ships the
   raw `.metal` source instead, and `MetalTerminalRenderer.makeLibrary`
   (`MetalTerminalRenderer.swift:2746`) compiles it at **runtime** via
   `device.makeLibrary(source:)` (`:2765`), which needs no toolchain — measured at 173ms on
   the first call and ~0ms after, on an M4 Pro. Until 2026-07-31 this patch used `exclude:`
   instead, which kept the shader out of the bundle and so made the vendored GPU renderer
   permanently unreachable, silently: avoiding the build-time compiler required dropping
   `.process`, but it never required dropping the file. `check-metal-renderer.sh` is the
   gate; `../.afk/research/performance-audit-2026-07-31.md` §1 is the argument.
2. `0002-index-iswrapped-buffer-absolute.patch` — fixes SwiftTerm
   [#494](https://github.com/migueldeicaza/SwiftTerm/issues/494) by indexing the
   wrapped-line flag buffer-absolute (`_lines[_y + _yBase]`) at `Buffer.swift:1171` and
   `:1211`, which previously used the screen-relative `_lines[_y]` and so corrupted
   scrollback on every narrowing. See "Known upstream risk" below.
3. `0003-trim-lines-on-narrowing-for-all-buffers.patch` — hoists the "trim each line to
   the new width" loop out of `if isReflowEnabled` at `Buffer.swift:522`, so it runs for
   the **alternate** buffer too. `isReflowEnabled` is just `hasScrollback`
   (`Buffer.swift:419`) and the alt buffer is built `scrollback: nil`
   (`Terminal.swift:694`), so narrowing left every `BufferLine` at its old width while
   `cols` shrank, and the next *widening* copied those stale cells back into the visible
   grid (`BufferLine.swift:197`). Under tmux — which lives in the alt buffer and repaints
   only deltas — that is content bleeding across pane and window boundaries. The loop must
   stay **after** `reflow`, which rewraps from the old width. Diagnosis:
   `../.afk/research/tmux-bleed-altbuffer-resize-2026-07-29.md`.
4. `0004-gate-resize-post-condition-behind-debug.patch` — wraps the `// DEBUG:
   Post-condition` block at `Buffer.swift:544` in `#if DEBUG`. Upstream ships it ungated
   while gating this file's five other debug blocks correctly, so it reads as a leftover: it
   walks the viewport **plus the entire scrollback** on every `resize` — the third such walk
   in that function, and every live-window-drag frame reaches it — and ends in `abort()`, a
   hard crash in release builds raised from inside a drag. Kept as `abort()` inside the guard
   so debug builds still fail as loudly as upstream intended. Unlike `0002`/`0003` it has no
   behavioural gate, deliberately: its whole effect is deleting work and deleting a crash
   path, so a passing check would only prove the compiler honours `#if DEBUG`. What guards it
   is the combined `Buffer.swift` hash plus both existing Buffer gates still passing with it
   applied.
5. `0005-add-dcs-ptmux-passthrough.patch` — adds a `PtmuxDcsHandler` branch to
   `dispatchDcs()` in `EscapeSequenceParser.swift`, plus a new `PtmuxDcsHandler.swift`, so
   DCS Ptmux sequences survive tmux's `allow-passthrough on` wrapping: the handler
   un-doubles tmux's `ESC` encoding and re-feeds the inner sequence, so OSC 52 clipboard,
   graphics and custom escapes from apps like neovim running inside tmux reach the outer
   terminal instead of being silently dropped. It is the only patch that adds a **new file**
   with no upstream counterpart, so its absence is a compile error rather than a silent one.
6. `0006-gate-linefeed-selection-clear-on-mouse-mode.patch` — gates
   `linefeed(source:)`'s `selection.selectNone()` on `terminal.mouseMode != .off`
   (`MacTerminalView.swift:888`). Upstream cleared the terminal selection on **every** LF
   whenever `allowMouseReporting` was true — which it is by default — so at a plain shell
   prompt (`mouseMode == .off`) each newline in streaming output wiped the user's selection
   before ⌘C could copy it, making copy/paste feel broken. Every other `allowMouseReporting`
   guard in that file already checked `mouseMode`; linefeed was the sole omission.

`vendor/` is gitignored, so the patches are committed as real artifacts instead —
`0001` through `0006` in `../patches/swiftterm/`, all pinned by
`../patches/swiftterm/SwiftTerm.pin`. Recreate the tree with:

```sh
./Scripts/bootstrap-vendor.sh          # from app/; --force to discard an existing tree
```

That does everything below and then delegates to `verify-vendor.sh` for the verdict,
propagating its exit code. It stages the clone in a temp directory and moves it into place
only once every patch has applied, so an interrupted run never leaves a half-built
`vendor/SwiftTerm` for the next one to puzzle over — and it refuses to repair an existing
mismatched tree in place, because a partly-patched checkout is indistinguishable from a
differently-patched one. It also checks that the tag still resolves to the commit the pin
names, which `verify-vendor.sh` only echoes cosmetically.

The manual equivalent, if you would rather see the steps than trust a script:

```sh
git clone --depth 1 --branch v1.15.0 \
    https://github.com/migueldeicaza/SwiftTerm.git vendor/SwiftTerm
chmod -R u+w vendor/SwiftTerm      # SPM checkouts are read-only; patch fails otherwise
patch -p1 -d vendor/SwiftTerm < patches/swiftterm/0001-ship-metal-shader-as-copy-resource.patch
patch -p1 -d vendor/SwiftTerm < patches/swiftterm/0002-index-iswrapped-buffer-absolute.patch
patch -p1 -d vendor/SwiftTerm < patches/swiftterm/0003-trim-lines-on-narrowing-for-all-buffers.patch
patch -p1 -d vendor/SwiftTerm < patches/swiftterm/0004-gate-resize-post-condition-behind-debug.patch
patch -p1 -d vendor/SwiftTerm < patches/swiftterm/0005-add-dcs-ptmux-passthrough.patch
patch -p1 -d vendor/SwiftTerm < patches/swiftterm/0006-gate-linefeed-selection-clear-on-mouse-mode.patch
app/Scripts/verify-vendor.sh       # confirms the result matches the pin (all six patches)
(cd app && ./Scripts/check-reflow.sh)            # proves 0002 actually took
(cd app && ./Scripts/check-altbuffer-resize.sh)  # proves 0003 actually took
(cd app && ./Scripts/check-metal-renderer.sh)    # proves 0001 ships a REACHABLE shader
```

All six patches are required. `verify-vendor.sh` exits `2` naming the specific file if one
is missing. Note that `0002`, `0003` and `0004` patch the **same file**, so the pin carries a
single combined `Buffer.swift` hash: a tree with only some of them matches neither the patched
nor the upstream hash and lands in the exit-`3` "unknown revision" branch. That is
deliberate — half-patched is not a state this project supports, and it is louder than a
hash that quietly tolerated either.

Earlier revisions of this file said to "exclude the shader resource in its
`Package.swift` (the change is annotated in place)" — i.e. the only description of the
patch lived *inside the ignored file*, so it could not survive losing that file. That is
fixed: the patch is now reproducible from git, and `verify-vendor.sh` proves the result
byte-for-byte.

Provenance is mechanically established rather than assumed: a full recursive diff of the
vendored tree against the upstream `v1.15.0` tarball (commit `dd2fb8a`) reported **exactly
one** differing entry, `Package.swift`. Every other file — including `Buffer.swift` — was
byte-identical to upstream, which is why the #494 defect is upstream's and not something
introduced here. As of 2026-07-29 there are **two** differing entries, `Package.swift` and
`Buffer.swift`, the latter carrying patches `0002` and `0003`; the pin records the upstream
hash of `Buffer.swift` alongside the patched one precisely so "re-vendored, patch forgotten"
stays a nameable state rather than an unexplained hash mismatch. That byte-identical
baseline is also what establishes both `Buffer.swift` defects as **upstream's**: the file
was untouched here before either patch, so neither was self-inflicted.

To restore the stock dependency once
`xcodebuild -downloadComponent MetalToolchain` has run, change `Package.swift`
back to:

```swift
.package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.15.0")
```

Note that **upstream** is correct here — CodeEdit pins `thecoolwinter/SwiftTerm`,
a fork last pushed 2025-07-17.

## Known upstream risk

[SwiftTerm #494](https://github.com/migueldeicaza/SwiftTerm/issues/494) —
"Buffer reflow produces duplicate/orphan lines when narrowing terminal" — is still
**open upstream**, and is now **patched and gated locally** (2026-07-29). It is no longer
untested here; the history of how it came to be *claimed* tested is kept below on purpose.

This section previously said the Step 0 harness "could not reproduce it across
three deterministic reflow tests," and concluded the risk was reduced. **That
conclusion was wrong; corrected 2026-07-27.** The defect requires a non-zero
scrollback offset to manifest, and the harness never established one —
`git show 1e84dd0~1:spike/Tests/SpikeGatesTests/ReflowGateTests.swift | grep -c yBase`
returns `0`. Two of the three cases ran at `_yBase == 0`, where the defect is
*structurally inexpressible*; the third had scrollback but asserted only
duplicate-token counts, so the orphaning half went unchecked. A blind test
passing is absence of evidence, not evidence of absence.

The defect is real and present in the vendored tree. `Buffer.swift:1171` and
`:1211` set `_lines[_y].isWrapped = true` with a **screen-relative** index, five
and thirteen lines from `:1176`/`:1224` which correctly use the
**buffer-absolute** `_lines[_y + _yBase]` (`_y` is screen-relative —
`Buffer.swift:22,42-43`). Since `isWrapped` is the only flag reflow consults for
logical-line boundaries, a non-empty scrollback makes it join a falsely-wrapped
line to an unrelated neighbour and split a genuinely-wrapped one. That mangles
history silently rather than visibly. Upstream's partial fix (`protectedLines`)
is on unmerged branch `reflow` @ `0619254f`; vendored v1.15.0 lacks it.

**Resolution (2026-07-29): patched locally, with a gate that can fail.** Of the options
triaged in `../.afk/plans/emulator-foundation-probe-and-vendor-integrity.md` §5–6, "patch
locally" was chosen. `../patches/swiftterm/0002-index-iswrapped-buffer-absolute.patch` makes
both sites buffer-absolute; `./Scripts/check-reflow.sh` is the gate, and `verify-vendor.sh`
now hard-fails a tree missing the patch.

The plan rejected local patching on the grounds that *core buffer surgery in a repo with
zero tests buys correctness that cannot be verified* — so the gate, not the two-line diff,
is the actual deliverable. It was validated by falsification rather than by passing: against
the **unpatched** vendored tree it fails **6 of 8** cases (exit `1`), naming the corruption
concretely, e.g. row 5 of scrollback reading `|T0006sss|` before narrowing and `||` after;
against the patched tree all 8 pass (exit `0`). Reverting the patch reproduces the failures.
A gate that had passed both ways would have been worth nothing, which is exactly what
happened the first time.

The fix is **local, not upstream**. Upstream's own partial fix (`protectedLines`) is still
on unmerged branch `reflow` @ `0619254f`, and #494 remains open, so a SwiftTerm upgrade will
*not* bring this fix with it — it will bring back the defect unless `0002` is re-applied.
That is what the dual hashes in `SwiftTerm.pin` and the hard failure in `verify-vendor.sh`
are for. If duplicated or orphaned lines ever appear after narrowing a window with
scrollback present, `TerminalPane.sizeChanged` is still the hook to instrument.
