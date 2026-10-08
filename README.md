<p align="center">
  <img src="app/Resources/icon-1024.png" width="132" alt="Goblin Portal app icon">
</p>

# Goblin Portal

A native macOS terminal, written in Swift 6 / AppKit, with **no AI features** — built
to host [`agent-afk`](https://github.com/griffinwork40/agent-afk)'s REPL properly.

The "no AI" part is a deliberate design constraint, not an omission. The agent
lives *in* the terminal; the terminal itself should be a fast, correct, native
window that gets out of the way. The bar is that it be beautiful and
user-friendly as hell before it is clever.

Personal project. Renamed from Umber to **Goblin Portal** on 2026-09-15.

## Status — v1.1

Launchable and daily-driven.

**Terminal.** Your login shell (`$SHELL -l`, so your real `PATH` and rc files load) in a
real `.app` bundle. Font sizing that sticks — ⌘+/⌘− zoom every tab and persist across
relaunch, ⌘0 resets, 14pt default. Copy, paste, select-all, full screen, and find
(⌘F, ⌘G/⌘⇧G, ⌘E) — the last is SwiftTerm's own find bar, so it matches one result at a
time rather than highlighting all of them.

**Two levels of tabs, on purpose.** A **Space** is one window per project root, and it is
a real macOS window tab — so ⌘⇧[ / ⌘⇧] cycling, the tab overview, drag-to-reorder,
drag-out-to-detach and Merge All Windows all work without being implemented. Inside a
Space, **documents** live in a hand-rolled strip (⌘T, ⌘1–⌘9, ⌘⌥←/→), which has to be
custom: a system window tab *is* an `NSWindow`, so a mixed terminal/editor strip could not
share one full-height sidebar. The strip hides itself at a single document, so
one-terminal Goblin Portal still just looks like a terminal.

**Sidebar.** A file tree that follows the shell's working directory — by asking the
kernel, not by relying on shell integration, so it cannot be broken by your dotfiles.
Per-file **git status** badges with directory roll-up and an ambient branch +
ahead/behind line. A **Source Control panel** (stage, unstage, discard, commit, push,
pull, diff viewer) lives below the file tree (shipped PR #132). Double-click opens a
file in a viewer/editor pane, which is a second document kind sharing the strip.

**Themes.** `classic-repaired` by default (was `umber` until 2026-08-20, `Config.swift:265`),
gated by 560 contrast assertions including falsification cases.
`umber`, `afk-dark`, `afk-light` (the light one) and `tokyo-night` are one
config line away, and `classic` installs nothing at all.

**Not built:** profiles.

**Partial:** splits (v2 — ⌘⇧\\ splits right, ⌘⇧- splits down, up to 4 panes per tab;
split state not persisted across launches) · syntax-highlighting in the editor
(14 languages, regex-based; no tree-sitter, no code intelligence).

**Shell integration.** Set `GOBLIN_PORTAL_INTEGRATION` in your shell environment;
`shell-integration.zsh` (bundled with the app) sources automatically and emits
OSC 7 on every `precmd` and OSC 133 A/C/D around commands.

## Install

Requires macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/griffinwork40/goblin-portal.git
cd goblin-portal/app
./Scripts/bootstrap-vendor.sh          # once: fetches + patches the vendored emulator
./Scripts/make-app-bundle.sh release   # omit "release" for a debug build
open "build/Goblin Portal.app"
```

`bootstrap-vendor.sh` exists because `vendor/SwiftTerm` is gitignored: it clones the pinned
upstream revision, applies the twelve local patches in order, and verifies the result against
recorded hashes. It is idempotent — run it again and it says so and stops.

`swift run GoblinPortal` is a faster iteration loop, but the bundle is what you want for real
use — Dock icon, Spotlight, behaves like an app rather than a stray process.

First stop after launching is **⌘,**, which writes a commented starter config to
`~/.config/goblin-portal/config.json` and opens it. **⌘R** reloads it live; any setting it
could not apply is named in a dismissible banner under the titlebar. The full field
reference — font, cursor, scrollback, shell, theme, renderer — is in
[`app/README.md`](app/README.md).

> **A downloaded build is ad-hoc signed, and Gatekeeper will refuse it.** There is no paid
> Developer ID behind this project, so a release binary is not notarised. If you download
> one rather than building it yourself:
> ```sh
> xattr -dr com.apple.quarantine "/Applications/Goblin Portal.app"
> ```
> A bundle you built locally is not quarantined and needs nothing.

## Keymap

⌘N new Space · ⌘⇧N new Space in a new window · ⌘O open folder as a Space · ⌘T new document ·
⌘W close document (falls through to the Space when it is the last) · ⌘⇧W close Space ·
⌘⌥← / ⌘⌥→ cycle documents · ⌘1–⌘9 select document · ⌘B toggle sidebar · ⌘+ / ⌘− / ⌘0 zoom ·
⌘, edit config · ⌘R reload config · ⌘F find · ⌘G / ⌘⇧G next & previous · ⌘E use selection ·
⌥⌘F find and replace (editor only) · ⌘Z / ⌘⇧Z undo & redo (editor only) · ⌃⌘F full screen.

## Layout

| Path | What |
|------|------|
| `app/` | The application. SwiftPM package, 99 source files, **none over 350 lines**. See [`app/README.md`](app/README.md) for the configuration reference and the dependency note. |
| `app/Scripts/` | Bundle assembly, icon generation, and the verification scripts. |
| `vendor/SwiftTerm` | **Gitignored.** Upstream [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) v1.15.0 plus **twelve** local patches in `patches/swiftterm/`. Run `app/Scripts/bootstrap-vendor.sh`. |
| `.afk/` | Plans and research — the reasoning behind the structural decisions, kept in the repo on purpose. `.afk/plans/native-swift-terminal-afk-host.md` is the plan of record. |

There is no `.xcodeproj` — first-party source stays all text, so it is diffable and
scriptable. Everything in `app/Sources/GoblinPortal/` is readable, greppable, and under
the 350-LOC ceiling. `AFK.md` has the full architecture note.

## Verification

**There is no test target and no CI.** Verification is 39 `check-*.sh` scripts plus
`verify-vendor.sh`, each of which compiles a shipped source file standalone and runs a
truth table against it. That is an unusual choice and it is deliberate: with no test target,
correctness depends on a reader holding a whole file in context, which is also why the
350-line ceiling is mechanically enforced (`check-file-size.sh`).

```sh
cd app
./Scripts/check-keybindings.sh      # 17-case truth table over the ⌘-chord table
./Scripts/check-theme-contrast.sh   # 560 assertions, incl. falsification cases
./Scripts/check-git-status.sh       # 58 cases over real git fixtures
./Scripts/verify-vendor.sh          # is vendor/ the pinned revision, with all twelve patches?
```

Twelve of the nineteen run on a fresh clone with no build; the rest need `swift build`, a
window server, or a built bundle. Several were validated by **falsification** — reverting
the patch they guard makes them fail — which is the only reason to believe the passes mean
anything. `GOBLIN_PORTAL_DIAG=1` dumps resolved font, theme, scrollback and git state to stderr.

## Known risks

**SwiftTerm [#494](https://github.com/migueldeicaza/SwiftTerm/issues/494) is still open
upstream, and patched locally.** Buffer reflow set a wrapped-line flag using a
screen-relative index where the adjacent content write used a buffer-absolute one, so with
non-empty scrollback the flag landed `yBase` rows off target and reflow silently mangled
history — joining a falsely-wrapped line to an unrelated neighbour, splitting a genuinely
wrapped one. Fixed here by `patches/swiftterm/0002`, gated by `check-reflow.sh`, which fails
6 of 8 cases without it. **A SwiftTerm upgrade reintroduces the defect unless 0002 is
re-applied** — which is what `verify-vendor.sh` exists to catch.

This entry used to say three deterministic tests "could not reproduce it, so it is *reduced,
not closed*." That was wrong. Two of those tests ran where the defect is structurally
inexpressible and the third asserted only duplicate tokens, never missing ones — absence of
evidence, not reduced risk. The history is kept because the lesson is the point.

**A second reflow defect was found hours later in the same function** — narrowing the
alternate buffer left stale cells that reappeared on widening, which is what made tmux panes
bleed into each other. Patched (`0003`), gated by `check-altbuffer-resize.sh`. The reflow
gate passing had never been evidence about this, because it only ever exercised the normal
buffer.

**G6, the multi-hour soak, is not closed.** It retires only through real daily use, never a
test.

## License

MIT — see [`LICENSE`](LICENSE).

Goblin Portal vendors MIT-licensed work by others: [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
(Miguel de Icaza and the xterm.js authors). [Ghostty](https://github.com/ghostty-org/ghostty)
(Mitchell Hashimoto) was linked as `libghostty-spm` during a probe phase and is no longer linked
(removed PR #95). Two of the shipped colour palettes are ports of other people's published themes.
Full attribution, including which dependencies are resolved but *not* shipped and how that was
verified, is in [`THIRD-PARTY-LICENSES.md`](THIRD-PARTY-LICENSES.md).
