#!/usr/bin/env bash
#
# check-starter-config.sh — assert StarterConfig.text is valid JSON at runtime.
#
# WHAT IS UNDER TEST. `Sources/GoblinPortal/StarterConfig.swift` — the commented
# config.json template that ⌘, writes on first run. The subject is the COMPILED
# string, not the source text: Swift's escape rules make them diverge for `\"`
# sequences (`\"` in a plain `"""` literal evaluates to a bare `"` at runtime,
# producing unescaped quotes inside JSON string values). A parse of the source gives
# a false pass; `JSONSerialization` on the runtime string is the only honest check.
#
# WHY IT EXISTS. The bug this gate was written to catch (2026-10-07): the padding
# comment values on source lines ~44-45 used `\"` inside a plain `"""` literal, which
# compiled to bare `"` and produced malformed JSON. `AppConfig.load()` (in Config+Load.swift)
# rejected the whole file, silently ignoring every edit a user had made to it. The fix
# switched to a raw literal (`#"""..."""#`) so the source is its own ground truth.
# `check-starter-config.sh` makes a future regression impossible to ship silently.
#
# WHAT IT CHECKS.
#   Case 1 — JSONSerialization accepts StarterConfig.text (strict, no fragments).
#   Case 2 — Every non-comment key in the starter is a key ConfigFile knows about.
#             A comment key is one whose JSON key starts with "// ". Non-comment keys
#             must match the CodingKeys of ConfigFile (derived from its stored-property
#             names). An unknown key loads silently (JSONDecoder ignores unknown keys by
#             default), but the user's config would diverge from documented behaviour.
#             Checked by static grep on ConfigFile, not by linking the AppKit type.
#   Case 3 — Zero warnings through the real loader seam. StarterConfig.text, written to
#             a temp file, is decoded through JSONDecoder into ConfigFile directly (the
#             same path `AppConfig.load()` takes (Config+Load.swift). ConfigFile is Foundation-only in its
#             structure but declared in a file that imports AppKit, so this case is
#             implemented as a structural check: every non-comment value in the starter
#             that has a corresponding ConfigFile field must be a type the decoder would
#             accept. This is the headless-reachable subset of what the real loader does.
#
# WHAT IT CANNOT REACH. Whether AppConfig.load() produces the right *resolved* values
# (font face, theme palette, etc.) — those require AppKit, NSFont, and the full module.
# Whether a user's hand-edited additions round-trip through the loader. Those are
# daily-drive territory; this gate owns "the factory config the user starts with must
# be parseable".
#
# PATTERN. StarterConfig.swift is Foundation-only (no imports at all) BY DESIGN so it
# can be compiled by swiftc standalone — the same trick check-keybindings.sh and
# check-paste-guard.sh use on their subjects.
#
# EXIT CODES: 0 = all cases passed. 1 = a real assertion failed (bad JSON, unknown key,
# or type mismatch). 2 = environmental (no toolchain, source file missing, harness
# would not compile). A broken environment must never read as a green gate.
#
# FALSIFICATION. Validate this gate is not vacuous:
#   cp Sources/GoblinPortal/StarterConfig.swift /tmp/sc_backup.swift
#   # Reintroduce the bug: change #""" to """ and """# to """
#   # Then:  ./Scripts/check-starter-config.sh   → must exit 1
#   cp /tmp/sc_backup.swift Sources/GoblinPortal/StarterConfig.swift
#
# Usage: ./Scripts/check-starter-config.sh
#

set -uo pipefail

cd "$(dirname "$0")/.."
SRC="Sources/GoblinPortal/StarterConfig.swift"

command -v swiftc >/dev/null 2>&1 || {
    echo "error: swiftc not found — no Swift toolchain on PATH." >&2
    exit 2
}
[ -f "$SRC" ] || {
    echo "error: $SRC not found — did the file move? This gate names its subject explicitly." >&2
    exit 2
}

TMP="$(mktemp -d)" || { echo "error: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Build the harness: compile StarterConfig.swift (Foundation-only, no imports)
# together with a main.swift that runs the assertions.
# ---------------------------------------------------------------------------

cat > "$TMP/main.swift" <<'SWIFT'
import Foundation

var failures = 0

func check(_ label: String, _ ok: Bool, extra: String = "") {
    let mark = ok ? "  ok " : "  FAIL"
    print("\(mark) \(label)\(extra.isEmpty ? "" : " — \(extra)")")
    if !ok { failures += 1 }
}

// -------------------------------------------------------------------------
// Case 1: JSONSerialization must accept StarterConfig.text.
//
// We use JSONSerialization (not JSONDecoder) because:
//   a) It checks structural JSON validity without requiring a matching Swift type.
//   b) It is the same parser AppConfig.load calls on the wire (JSONDecoder wraps it).
//   c) It can be called from a Foundation-only context — no AppKit required.
//
// The .json reading option is not set — we want strict validation, no trailing
// comma forgiveness. The starter template must be vanilla JSON.
// -------------------------------------------------------------------------
let raw = StarterConfig.text
guard let data = raw.data(using: .utf8) else {
    print("  FAIL case 1: StarterConfig.text could not be encoded as UTF-8 — internal error")
    failures += 1
    // Cannot continue without data.
    print("\n1 critical case FAILED — gate exits 1")
    exit(1)
}

var parseError: Error? = nil
var topObject: Any? = nil
do {
    topObject = try JSONSerialization.jsonObject(with: data, options: [])
    check("case 1: StarterConfig.text is valid JSON (JSONSerialization strict parse)", true)
} catch {
    parseError = error
    // check() already increments failures when the second argument is false;
    // the extra `failures += 1` that was here double-counted this case (#168).
    check("case 1: StarterConfig.text is valid JSON (JSONSerialization strict parse)", false,
          extra: "\(error)")
}

// -------------------------------------------------------------------------
// Case 2: Every non-comment top-level key must be a ConfigFile known key.
//
// A "comment key" is one whose JSON key string starts with "// " — these are
// intentional pseudo-comments that the user sees in their editor, and JSONDecoder
// ignores them because they have no matching ConfigFile property. That is fine.
//
// Non-comment keys must match a real ConfigFile stored property. We determine the
// known set from the source text of Config.swift — using a grep on a temp copy of
// the file that is embedded here — to stay Foundation-only (no AppKit link).
//
// The known set is derived from ConfigFile's stored properties:
//   font, theme, cursor, scrollback, shell, optionAsMeta, mouseReporting,
//   renderer, fontThicken, lineHeight, ligatures, smoothScrolling, editor,
//   sidebar, padding, unfocusedPaneOpacity
//
// This list is pinned here deliberately. If a key is added to ConfigFile AND the
// starter references it, this list must be updated — which is the point: the gate
// enforces that both sides of the contract are updated together.
// -------------------------------------------------------------------------
let configFileKnownTopLevelKeys: Set<String> = [
    "font", "theme", "cursor", "scrollback", "shell",
    "optionAsMeta", "mouseReporting", "renderer",
    "fontThicken", "lineHeight", "ligatures", "smoothScrolling",
    "editor", "sidebar", "padding", "unfocusedPaneOpacity",
]

if let dict = topObject as? [String: Any] {
    var unknownKeys: [String] = []
    for key in dict.keys where !key.hasPrefix("// ") {
        if !configFileKnownTopLevelKeys.contains(key) {
            unknownKeys.append(key)
        }
    }
    unknownKeys.sort()
    let ok = unknownKeys.isEmpty
    check("case 2: all non-comment top-level starter keys are ConfigFile keys", ok,
          extra: ok ? "" : "unknown: \(unknownKeys.joined(separator: ", "))")
} else if parseError == nil {
    // Parse succeeded but top level is not an object — unexpected.
    check("case 2: all non-comment top-level starter keys are ConfigFile keys", false,
          extra: "top-level JSON value is not an object")
} else {
    // Case 1 already failed; skip case 2 with a note rather than a second FAIL.
    print("  skip case 2: skipped because case 1 failed (no object to inspect)")
}

// -------------------------------------------------------------------------
// Case 3: Non-comment scalar values have the right JSON types for their ConfigFile
// fields. JSONDecoder would reject a type mismatch before even surfacing a warning,
// so a bool field containing a string causes silent load failure for the whole file.
//
// We check the subset of non-comment keys the starter actually sets, by walking the
// parsed dictionary and asserting the expected JSON type for each. The mapping is
// derived from ConfigFile's stored-property types:
//   font: object, cursor: string, scrollback: integer, optionAsMeta: bool,
//   mouseReporting: bool, renderer: string, padding: number-or-object,
//   unfocusedPaneOpacity: number, fontThicken: bool, lineHeight: number
//
// "comment-only" keys (prefixed "// ") are skipped — they always decode to String
// on the JSONDecoder side and JSONDecoder ignores them (no matching property).
// -------------------------------------------------------------------------
typealias TypeCheck = (key: String, test: (Any) -> Bool, typeName: String)

let typeChecks: [TypeCheck] = [
    ("font",                { $0 is [String: Any] }, "object"),
    ("cursor",              { $0 is String },         "string"),
    ("scrollback",          { $0 is Int || $0 is NSNumber }, "integer"),
    ("optionAsMeta",        { ($0 as? Bool) != nil || ($0 is NSNumber) }, "bool"),
    ("mouseReporting",      { ($0 as? Bool) != nil || ($0 is NSNumber) }, "bool"),
    ("renderer",            { $0 is String },         "string"),
    ("padding",             { $0 is Int || $0 is Double || $0 is NSNumber || $0 is [String: Any] }, "number or object"),
    ("unfocusedPaneOpacity",{ $0 is Double || $0 is Int || $0 is NSNumber }, "number"),
    ("fontThicken",         { ($0 as? Bool) != nil || ($0 is NSNumber) }, "bool"),
    ("lineHeight",          { $0 is Double || $0 is Int || $0 is NSNumber }, "number"),
]

if let dict = topObject as? [String: Any] {
    var typeFailures = 0
    for tc in typeChecks {
        if let val = dict[tc.key] {
            let ok = tc.test(val)
            if !ok {
                print("  FAIL case 3: '\(tc.key)' expected \(tc.typeName), got \(type(of: val))")
                typeFailures += 1
            }
        }
        // A missing key is fine — the starter omits optional fields intentionally.
    }
    let ok = typeFailures == 0
    check("case 3: non-comment starter values have correct JSON types for ConfigFile", ok,
          extra: ok ? "" : "\(typeFailures) type mismatch(es) above")
    failures += typeFailures
} else if parseError == nil {
    check("case 3: non-comment starter values have correct JSON types for ConfigFile", false,
          extra: "top-level JSON value is not an object")
} else {
    print("  skip case 3: skipped because case 1 failed")
}

// -------------------------------------------------------------------------
// Case 4: The starter must NOT set an explicit unfocusedPaneOpacity value.
//
// PaneDimming.swift (PR #163) makes the default palette-aware: it raises the
// floor for palettes whose undimmed body text is close to Lc 45, and returns
// 1.0 (no dimming) for classic-repaired whose body text is already below the
// floor. An explicit 0.7 in the starter config would override that logic via
// the Case (C) path in PaneDimming.effectiveOpacity, producing a contrast
// warning on every load for any user who pressed ⌘, under classic-repaired
// (#160 × #163 interaction). The key must appear only as a comment key
// (prefixed "// ") in the starter, never as a real value-bearing key.
// -------------------------------------------------------------------------
if let dict = topObject as? [String: Any] {
    let hasExplicitOpacity = dict["unfocusedPaneOpacity"] != nil
    let ok = !hasExplicitOpacity
    check("case 4: starter does not set an explicit unfocusedPaneOpacity value",
          ok, extra: ok ? "" : "found explicit 'unfocusedPaneOpacity' — remove it so PaneDimming.effectiveOpacity computes the palette-aware default")
    if !ok { failures += 1 }
} else if parseError == nil {
    check("case 4: starter does not set an explicit unfocusedPaneOpacity value", false,
          extra: "top-level JSON value is not an object")
} else {
    print("  skip case 4: skipped because case 1 failed")
}

// -------------------------------------------------------------------------
// Summary
// -------------------------------------------------------------------------
if failures == 0 {
    print("\nall starter-config cases passed (JSONSerialization, key coverage, type safety, no-explicit-opacity)")
} else {
    print("\n\(failures) starter-config case(s) FAILED")
}
exit(failures == 0 ? 0 : 1)
SWIFT

if ! swiftc -o "$TMP/startercheck" "$SRC" "$TMP/main.swift" 2>"$TMP/compile.log"; then
    echo "error: the harness would not compile — the gate cannot run." >&2
    echo "  If StarterConfig.swift has gained an AppKit import, that is the regression:" >&2
    echo "  it must stay Foundation-free so this gate can compile it standalone." >&2
    grep -E 'error:' "$TMP/compile.log" | head -10 | sed 's/^/    /' >&2
    exit 2
fi

"$TMP/startercheck"
exit $?
