#!/bin/bash
#
# Assert that the URL scheme allow-list in LinkScheme.swift matches the safety contract —
# that every allowed scheme is recognised as safe and every blocked one is rejected.
#
# WHAT IS UNDER TEST. `Sources/GoblinPortal/LinkScheme.swift` only. Foundation-only by design — its
# header says so — so it compiles standalone with swiftc and never links AppKit, SwiftTerm or
# libghostty. Same trick check-renderer-config.sh plays on Renderer.swift, check-cursor-style.sh
# on CursorStyle.swift, check-keybindings.sh on KeyBindings.swift. Compiling the SHIPPED file,
# not a copy of it, is the whole point: a check that restates the allow-list proves only that
# the check agrees with itself.
#
# WHY IT EXISTS. SwiftTerm's plain-text detector (`ghosttyImplicitLinkRegex`,
# `Terminal.swift:6204`) matches many schemes from raw terminal output — https?://, mailto:,
# ftp://, file:, ssh:, git://, tel:, magnet:, ipfs://, gemini://, gopher://, news:, and more.
# OSC 8 payloads are arbitrary. `openSafeURL`'s scheme allow-list is therefore the PRIMARY
# defence for every detected link — plain-text and OSC 8 alike. An incorrect entry in
# `LinkScheme.allowed`, or a bug in `isSafe`, could open arbitrary URL handlers on behalf of
# any program that prints to a pty. This gate makes that predicate auditable standalone,
# without a window server, a running emulator, or `swift build`.
#
# THE HARNESS DOES NOT RESTATE THE ALLOW-LIST. The truth table exercises the SHIPPED
# `LinkScheme.allowed` set via `LinkScheme.isSafe`; it does not hard-code {"https","http",
# "file"} in the shell. A harness that restates the table proves only that the harness
# agrees with itself, not that the allow-list is correct.
#
# Validated by falsification: adding "mailto" to `LinkScheme.allowed` makes case 7 fail;
# removing "https" makes case 1 fail; mistyping `s.lowercased()` as `s` in `isSafe` makes
# case 3 fail.
#
# Usage:
#   ./Scripts/check-links.sh            # run all cases
#   ./Scripts/check-links.sh --quiet    # summary line and failures only
#
# Exit codes:
#   0  every safe scheme is accepted, every blocked scheme is rejected, case insensitivity works
#   1  a real failure — the allow-list or isSafe predicate is wrong
#   2  environmental — no swiftc, source file missing, or a harness that would not compile.
#      Never conflated with 1: a broken environment must not read as a green gate.

set -uo pipefail

QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1
say() { [[ "$QUIET" == "1" ]] || echo "$@"; }

cd "$(dirname "$0")/.."
SRC="Sources/GoblinPortal/LinkScheme.swift"

command -v swiftc >/dev/null 2>&1 || {
  echo "error: swiftc not found — no Swift toolchain on PATH." >&2
  exit 2
}
[[ -f "$SRC" ]] || { echo "error: $SRC missing." >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Swift only allows top-level code in a file literally named main.swift, hence the subdir
# rather than a descriptive filename.
mkdir -p "$TMP/pure"
cat > "$TMP/pure/main.swift" <<'SWIFT'
import Foundation

var bad = 0

func expectSafe(_ scheme: String?, _ label: String) {
    let result = LinkScheme.isSafe(scheme)
    if !result {
        print("FAIL \(label): isSafe(\(scheme.map { "\"\($0)\"" } ?? "nil")) returned false, want true")
        bad += 1
    }
}

func expectBlocked(_ scheme: String?, _ label: String) {
    let result = LinkScheme.isSafe(scheme)
    if result {
        print("FAIL \(label): isSafe(\(scheme.map { "\"\($0)\"" } ?? "nil")) returned true, want false")
        bad += 1
    }
}

// ---- 1–4. Schemes that MUST be accepted -----------------------------------------------
// These are the three members of LinkScheme.allowed. The harness does not restate them;
// it exercises isSafe so that a bug in isSafe is caught even if allowed is correct.
expectSafe("https",  "https — primary web scheme")
expectSafe("http",   "http — plain web scheme")
expectSafe("file",   "file — build tool / compiler output; allowed to match Terminal.app and Ghostty")
// Case insensitivity: RFC 3986 §3.1 normalises scheme to lower case; isSafe must follow suit.
expectSafe("HTTPS",  "HTTPS — case insensitive")

// ---- 5–11. Schemes that MUST be blocked -----------------------------------------------
// ghosttyImplicitLinkRegex (Terminal.swift:6204) matches mailto:, ftp://, ssh:, git://, tel:,
// magnet:, and many more from plain terminal text. All must be blocked here.
expectBlocked("javascript", "javascript — browser sandbox escape")
expectBlocked("mailto",     "mailto — opens mail client; matched by plain-text detector")
expectBlocked("ftp",        "ftp — matched by plain-text detector")
expectBlocked("ssh",        "ssh — matched by plain-text detector; invokes terminal apps")
expectBlocked("data",       "data — arbitrary content injection")
expectBlocked("",           "empty string — no scheme means uncategorised")
expectBlocked(nil,          "nil scheme — URL(string:) may produce this for relative references")

print(bad == 0 ? "ALL-OK" : "SOME-FAILED")
SWIFT

if ! swiftc -O -o "$TMP/linkscheck" "$SRC" "$TMP/pure/main.swift" 2>"$TMP/compile.log"; then
  echo "error: $SRC would not compile standalone — the gate cannot run." >&2
  echo "  That file is Foundation-only on purpose so this is possible. If it now needs" >&2
  echo "  AppKit or SwiftTerm, the pure predicate and the live action have been re-merged" >&2
  echo "  and the split that made LinkScheme.swift checkable is gone — that is the thing to" >&2
  echo "  fix, not this script." >&2
  sed 's/^/    /' "$TMP/compile.log" >&2
  exit 2
fi

out="$("$TMP/linkscheck" 2>&1)"
if [[ "$out" == *"ALL-OK"* ]]; then
  say "  ok  https, http, file accepted; HTTPS accepted (case-insensitive)"
  say "  ok  javascript, mailto, ftp, ssh, data, empty string, nil rejected"
  echo
  echo "all link-scheme cases passed (4 safe + 7 blocked)"
  exit 0
fi

echo "✗ FAIL: $SRC's scheme allow-list or isSafe predicate is wrong:" >&2
echo "$out" | sed 's/^/    /' >&2
exit 1
