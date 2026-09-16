#!/bin/bash
#
# Assert that a `renderer` string in config.json maps to the renderer it names — and that an
# unrecognised one maps to NOTHING, so AppConfig.load() can warn and degrade.
#
# WHAT IS UNDER TEST. `Sources/GoblinPortal/Renderer.swift` only. That file is Foundation-only BY
# DESIGN — its header says so — precisely so it can be compiled on its own with swiftc and
# never link AppKit, SwiftTerm, or the app. Same trick check-keybindings.sh plays on
# KeyBindings.swift and check-cwd-follow.sh plays on ShellDirectory.swift. Compiling the
# SHIPPED file, not a copy of it, is the whole point: a check that restates the table proves
# only that the check agrees with itself.
#
# WHY IT IS SEPARATE FROM check-metal-renderer.sh. Different unit, different environment.
# That script needs `swift build`, the vendored SwiftTerm, a Metal device and a window
# server, and it exits 2 without them. This one needs swiftc and one 90-line source file.
# Folding the mapping into it would make the cheapest check in the pair unavailable on
# exactly the machines where the expensive one cannot run — and the mapping is also the half
# most likely to break, because it is hand-maintained spellings rather than a vendor API.
#
# WHY IT EXISTS AT ALL. Every behavioural case in check-metal-renderer.sh calls SwiftTerm's
# `setUseMetal` directly and therefore bypasses `Renderer.named` completely. So before this
# script, a typo in the mapping table would ship with that gate still green, and the symptom
# would be the quietest possible one: a config line that reads correctly, parses without a
# warning, and does nothing. That is the same class of silent failure patch 0001 caused for
# the life of the project.
#
# Usage:
#   ./Scripts/check-renderer-config.sh            # run all cases
#   ./Scripts/check-renderer-config.sh --quiet    # summary line and failures only
#
# Exit codes:
#   0  every documented spelling maps as promised and every unknown one is rejected
#   1  a real failure — the mapping, the round-trip, or the default is wrong
#   2  environmental — no swiftc, source file missing, or a harness that would not compile.
#      Never conflated with 1: a broken environment must not read as a green gate.

set -uo pipefail

QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1
say() { [[ "$QUIET" == "1" ]] || echo "$@"; }

cd "$(dirname "$0")/.."
SRC="Sources/GoblinPortal/Renderer.swift"

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
func expect(_ raw: String, _ want: Renderer?, _ label: String) {
    let got = Renderer.named(raw)
    if got != want {
        print("FAIL \(label): Renderer.named(\"\(raw)\") -> \(String(describing: got)), "
              + "want \(String(describing: want))")
        bad += 1
    }
}

// The two spellings the starter config template and app/README.md promise a user.
expect("coretext", .coreText, "canonical coretext")
expect("metal", .metal, "canonical metal")

// The generous spellings Renderer.named's own comment calls deliberate, because the input is
// a hand-edited JSON file and the failure mode of a strict match is a silently ignored
// setting. Each of these is the difference between a working line and a dead one.
expect("CoreText", .coreText, "case folded")
expect("core-text", .coreText, "hyphenated")
expect("core_text", .coreText, "underscore folded to hyphen")
expect("gpu", .metal, "gpu alias")
expect("cpu", .coreText, "cpu alias")
expect("coregraphics", .coreText, "coregraphics alias")
// `cg` and `core-graphics` are accepted by Renderer.named but were documented nowhere and
// covered by nothing until this line. An alias with no assertion behind it is the same
// hand-maintained table entry as the others, minus the gate.
expect("cg", .coreText, "cg alias")
expect("core-graphics", .coreText, "core-graphics alias")

// The failures that must STAY failures. nil is what lets AppConfig.load() append a warning
// and fall back; a mapping that guessed here would turn a typo into a silent renderer switch.
expect("bogus-value", nil, "unknown value rejected")
expect("", nil, "empty string rejected")
expect("METAL ", nil, "trailing space not silently trimmed")

// configName must round-trip, because it is the exact spelling the warning tells the user to
// type. Driven off allCases so adding a case cannot leave this assertion behind.
for r in Renderer.allCases where Renderer.named(r.configName) != r {
    print("FAIL round-trip: \(r).configName = \"\(r.configName)\" does not map back to \(r)")
    bad += 1
}

// configNames is what the warning text interpolates. If it ever came back empty the user
// would be told "expected one of:" and then nothing.
if Renderer.configNames.isEmpty {
    print("FAIL configNames: empty, so AppConfig.load()'s warning would name no valid values")
    bad += 1
}

// The default is the conservative one, and it is conservative on purpose: the GPU path is
// upstream-experimental and its speedup here is unmeasured. Flipping it is a legitimate
// decision — but it must be a deliberate edit HERE too, not something that drifts in.
if Renderer.default != .coreText {
    print("FAIL default: Renderer.default is \(Renderer.default), expected .coreText")
    bad += 1
}

print(bad == 0 ? "ALL-OK" : "SOME-FAILED")
SWIFT

if ! swiftc -O -o "$TMP/renderercheck" "$SRC" "$TMP/pure/main.swift" 2>"$TMP/compile.log"; then
  echo "error: $SRC would not compile standalone — the gate cannot run." >&2
  echo "  That file is Foundation-only on purpose so this is possible. If it now needs" >&2
  echo "  AppKit or SwiftTerm, the pure decision and the live action have been re-merged" >&2
  echo "  and the split that made Renderer.swift checkable is gone — that is the thing to" >&2
  echo "  fix, not this script." >&2
  sed 's/^/    /' "$TMP/compile.log" >&2
  exit 2
fi

out="$("$TMP/renderercheck" 2>&1)"
if [[ "$out" == *"ALL-OK"* ]]; then
  say "  ok  every documented spelling maps as promised; unknown values rejected"
  say "  ok  configName round-trips for every case; default is coretext"
  echo
  echo "all renderer-config cases passed (13 mappings + round-trip + default)"
  exit 0
fi

echo "✗ FAIL: $SRC's config-string mapping is wrong:" >&2
echo "$out" | sed 's/^/    /' >&2
exit 1
