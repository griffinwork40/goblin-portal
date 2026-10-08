//
//  check-config-warnings-harness.swift
//  The assertions for `check-config-warnings.sh`, compiled against ConfigWarningPolicy.swift.
//
//  A separate file, not a heredoc, because the driver compiles this SAME file three
//  times — once against the shipped policy and once against each sed-mutated copy that
//  must fail — which is only clean when the harness is a file every build can name
//  (the `check-file-ops.sh` pattern).
//
//  Exit 0 = all cases passed, 1 = an assertion failed. Anything else is a crash,
//  which the driver maps to 2 (environmental).
//

import Foundation

var bad = 0
var cases = 0
func fail(_ label: String, _ msg: String) {
    print("  FAIL \(label): \(msg)")
    bad += 1
}
func ok(_ label: String) { print("  ok  \(label)") }

/// Run one case: `body` returns nil on success or a failure message.
func check(_ label: String, _ body: () -> String?) {
    cases += 1
    if let msg = body() { fail(label, msg) } else { ok(label) }
}

let home = "/Users/ann"
func banner(_ w: [String], home h: String = home) -> ConfigWarningPolicy.Banner? {
    if case .show(let b) = ConfigWarningPolicy.action(for: w, home: h) { return b }
    return nil
}

// Real warning strings, copied in shape from Config+Load.swift / Config+Theme.swift, so
// the cases exercise what the loader actually emits rather than placeholder text.
let cursorW = "cursor 'blok' unrecognised — using block"
let rendW = "renderer 'vulkan' unrecognised (expected one of: coretext, metal) — using metal"
let presetW = "theme.preset 'umbr' unrecognised — using classic-repaired"
let sbW = "scrollback must be >= 0 — using 1000"
let lhW = "lineHeight 9.0 is outside 0.8–2.0 — using 1.0"

// ── 1. A clean load hides the banner ───────────────────────────────────────────────────
check("CASE 1 clean load → .hide (a fixed file must clear a stale banner)") {
    ConfigWarningPolicy.action(for: [], home: home) == .hide ? nil : "got .show for zero warnings"
}

// ── 2. Blank entries are not warnings ──────────────────────────────────────────────────
check("CASE 2 whitespace-only entries → .hide") {
    ConfigWarningPolicy.action(for: ["", "  ", "\n"], home: home) == .hide ? nil : "blank text produced a banner"
}

// ── 3. One warning: shown verbatim, singular title, no overflow ────────────────────────
check("CASE 3 one warning → singular title, line verbatim, overflow 0") {
    guard let b = banner([cursorW]) else { return "no banner for a real warning" }
    if b.lines != [cursorW] { return "lines = \(b.lines)" }
    if b.overflow != 0 { return "overflow = \(b.overflow)" }
    if !b.title.contains("1 setting was") { return "title = \(b.title)" }
    return nil
}

// ── 4. De-duplication: the count is distinct problems, order preserved ─────────────────
check("CASE 4 duplicates collapse, first-seen order kept, title counts distinct") {
    guard let b = banner([presetW, cursorW, presetW, " \(cursorW) "]) else { return "no banner" }
    if b.lines != [presetW, cursorW] { return "lines = \(b.lines)" }
    if !b.title.contains("2 settings were") { return "title = \(b.title) (expected a count of 2)" }
    return nil
}

// ── 5. Overflow: at most maxVisibleLines shown; the rest counted and in the tooltip ────
check("CASE 5 five warnings → \(ConfigWarningPolicy.maxVisibleLines) lines + overflow 2, full list in fullText") {
    let all = [cursorW, rendW, presetW, sbW, lhW]
    guard let b = banner(all) else { return "no banner" }
    if b.lines != Array(all.prefix(3)) { return "lines = \(b.lines)" }
    if b.overflow != 2 { return "overflow = \(b.overflow)" }
    if b.fullText != all.joined(separator: "\n") { return "fullText dropped or reordered a warning" }
    if !b.title.contains("5 settings were") { return "title = \(b.title)" }
    return nil
}

// ── 6. Boundary: exactly maxVisibleLines has no overflow line ──────────────────────────
check("CASE 6 exactly maxVisibleLines warnings → overflow 0") {
    guard let b = banner([cursorW, rendW, presetW]) else { return "no banner" }
    return b.overflow == 0 && b.lines.count == 3 ? nil : "lines \(b.lines.count), overflow \(b.overflow)"
}

// ── 7. Whole-file rejection gets its own title, recognised from the shared builder ─────
check("CASE 7 invalid-JSON warning → 'every setting was ignored' title") {
    let w = ConfigWarningPolicy.invalidJSONWarning(path: "\(home)/.config/goblin-portal/config.json")
    if !ConfigWarningPolicy.isWholeFileRejection(w) { return "builder output not recognised: \(w)" }
    if ConfigWarningPolicy.isWholeFileRejection(cursorW) { return "a field warning read as whole-file" }
    guard let b = banner([w]) else { return "no banner" }
    return b.title.contains("every setting was ignored") ? nil : "title = \(b.title)"
}

// ── 8. The user's home path is abbreviated everywhere the banner prints ────────────────
check("CASE 8 home directory → ~ in lines and fullText, absolute path never shown") {
    let w = ConfigWarningPolicy.invalidJSONWarning(path: "\(home)/.config/goblin-portal/config.json")
    guard let b = banner([w]) else { return "no banner" }
    let shown = ([b.title, b.fullText] + b.lines).joined(separator: "\n")
    if shown.contains(home) { return "absolute home leaked: \(shown)" }
    return b.lines.first?.hasPrefix("~/.config/goblin-portal/config.json") == true ? nil : "lines = \(b.lines)"
}

// ── 9. Abbreviation respects path-component boundaries ─────────────────────────────────
check("CASE 9 /Users/ann2 is NOT abbreviated when home is /Users/ann") {
    let w = "shell '/Users/ann2/bin/zsh' is not executable — using /bin/zsh"
    let got = ConfigWarningPolicy.abbreviatingHome(w, home: home)
    return got == w ? nil : "rewrote a sibling user's path: \(got)"
}

// ── 10. Trailing slash on home, and a bare-home occurrence at end of string ────────────
check("CASE 10 home with trailing slash; home at end of string") {
    let a = ConfigWarningPolicy.abbreviatingHome("\(home)/x", home: home + "/")
    let b = ConfigWarningPolicy.abbreviatingHome("cwd is \(home)", home: home)
    return a == "~/x" && b == "cwd is ~" ? nil : "got '\(a)' and '\(b)'"
}

// ── 11. Pin: changing the visible-line budget is a deliberate act ──────────────────────
check("CASE 11 maxVisibleLines pinned at 3") {
    ConfigWarningPolicy.maxVisibleLines == 3 ? nil
        : "moved to \(ConfigWarningPolicy.maxVisibleLines) — if deliberate, update cases 5, 6 and 11"
}

if bad == 0 {
    print("\nall \(cases) config-warning policy cases passed")
} else {
    print("\n\(bad) of \(cases) config-warning policy case(s) FAILED")
}
exit(bad == 0 ? 0 : 1)
