# SPINE.md — Project Architecture Spine

> Auto-maintained by agent-afk at session end. Edit entries manually if needed; IDs are stable.


## Invariants

- **INV-001** (2026-09-17, spine-init): All Swift source files in Sources/ capped at 350 LOC; Scripts/ similarly enforced.
- **INV-002** (2026-09-17, spine-init): No AI features in the terminal itself; agent-afk runs as REPL guest.
- **INV-003** (2026-09-17, spine-init): SwiftTerm vendored at v1.15.0 with exactly six local patches; verify-vendor.sh enforces pin.
- **INV-004** (2026-09-17, spine-init): Bundle ID, env var prefix, code identifier all normalized to `goblin-portal`/`GoblinPortal`/`GOBLIN_PORTAL_`.
- **INV-005** (2026-09-17, spine-init): Single `main` branch; no feature branches or CI/test target; verification via 19 headless/GUI check-*.sh scripts.
- **INV-006** (2026-09-17, spine-init): GOBLIN_PORTAL_DIAG=1 env var dumps resolved font/theme/scrollback diagnostics to stderr.
- **INV-007** (2026-09-17, spine-init): Undo, Redo, Find-and-Replace wired to AppKit responder chain (target=nil); no Goblin Portal code behind them.
- **INV-008** (2026-09-17, spine-init): Theme preset `"umber"` survives as an easter egg; do not remove despite app rename to Goblin Portal.


## Explicitly Rejected Patterns

- **REJ-001** (2026-09-17, spine-init): Do not use fullSizeContentView for glass chrome activation; use SDK metadata instead.


## Taste Calls Made

- **TST-001** (2026-09-17, spine-init): Prefer native SwiftTerm rendering pipeline; GPU renderer (Metal) is optional, not default.
