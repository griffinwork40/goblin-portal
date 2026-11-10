#!/bin/bash
#
# Assert that FilePathDetector correctly identifies compiler-style file:line references
# in terminal output and rejects plain text, URLs, and other non-path strings.
#
# WHAT IS UNDER TEST. `Sources/GoblinPortal/FilePathDetector.swift` only.
# Foundation-only by design — its header says so — so it compiles standalone with
# swiftc and never links AppKit or SwiftTerm. Same trick check-links.sh plays on
# LinkScheme.swift.
#
# Compiling the SHIPPED file (not a copy) is the whole point: a check that restates
# the patterns proves only that the check agrees with itself.
#
# PATTERNS COVERED:
#   Absolute path:       /path/file.swift:42:10   (Swift/Clang/GCC/Go/Node/grep -n)
#   Rust arrow:          --> src/main.rs:7:3
#   Python traceback:    File "script.py", line 12
#   Relative path:       src/main.go:88:1
#   Trailing colon:      /path/file.c:33:          (GCC style)
#   Path with spaces:    /path/my file.swift:5:1   (NOT matched — spaces break the regex;
#                        documented limitation, matches Xcode's own behaviour)
#   Non-matches:         URLs, plain text, bare filenames
#
# FALSIFICATION. Two sed mutants are applied to a COPY (never the shipped file):
#   1. Remove the line-number group from the absolute pattern — detect returns nil.
#   2. Corrupt the Python keyword — python pattern stops matching.
# Both mutants must cause the cases that relied on them to FAIL (mutant kills).
# A mutant that does NOT kill its target case means the case was not testing what
# it claimed to test.
#
# Usage:
#   ./Scripts/check-file-path-detect.sh           # run all cases
#   ./Scripts/check-file-path-detect.sh --quiet   # summary and failures only
#
# Exit codes:
#   0  all 15+ cases passed and both mutants killed
#   1  a real failure — a pattern is wrong or a mutant survived
#   2  environmental — no swiftc, source file missing, or compile failure

set -uo pipefail

QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1
say() { [[ "$QUIET" == "1" ]] || echo "$@"; }

cd "$(dirname "$0")/.."
SRC="Sources/GoblinPortal/FilePathDetector.swift"

command -v swiftc >/dev/null 2>&1 || {
    echo "error: swiftc not found — no Swift toolchain on PATH." >&2
    exit 2
}
[[ -f "$SRC" ]] || { echo "error: $SRC missing." >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Build the harness Swift source
# ---------------------------------------------------------------------------
mkdir -p "$TMP/harness"
cat > "$TMP/harness/main.swift" <<'SWIFT'
import Foundation

var bad = 0

func expectMatch(
    text: String, column: Int,
    expectPath: String, expectLine: Int,
    label: String
) {
    guard let m = FilePathDetector.detect(in: text, near: column) else {
        print("FAIL \(label): got nil, want path=\(expectPath) line=\(expectLine)")
        bad += 1
        return
    }
    if m.path != expectPath || m.line != expectLine {
        print("FAIL \(label): got path=\(m.path) line=\(m.line), want path=\(expectPath) line=\(expectLine)")
        bad += 1
    }
}

func expectNil(text: String, column: Int, label: String) {
    if let m = FilePathDetector.detect(in: text, near: column) {
        print("FAIL \(label): got path=\(m.path) line=\(m.line), want nil")
        bad += 1
    }
}

func expectResolve(path: String, cwd: URL?, exists: Bool, label: String) {
    let result = FilePathDetector.resolve(path, cwd: cwd)
    if exists && result == nil {
        print("FAIL \(label): resolve returned nil, want non-nil")
        bad += 1
    } else if !exists && result != nil {
        print("FAIL \(label): resolve returned \(result!.path), want nil")
        bad += 1
    }
}

// ---- DETECT cases ----------------------------------------------------------------

// C1. Swift compiler absolute path with line+col
expectMatch(
    text: "/Users/alice/proj/Sources/Foo.swift:42:10: error: use of unresolved identifier",
    column: 10,
    expectPath: "/Users/alice/proj/Sources/Foo.swift",
    expectLine: 42,
    label: "C1 Swift compiler absolute path")

// C2. GCC/Clang absolute path with trailing colon
expectMatch(
    text: "/usr/include/stdio.h:33: warning: implicit declaration",
    column: 5,
    expectPath: "/usr/include/stdio.h",
    expectLine: 33,
    label: "C2 GCC trailing-colon style")

// C3. Go compiler: absolute path, line only
expectMatch(
    text: "/home/bob/go/src/main.go:88:1: syntax error",
    column: 20,
    expectPath: "/home/bob/go/src/main.go",
    expectLine: 88,
    label: "C3 Go compiler absolute path")

// C4. Node.js / TypeScript: absolute path
expectMatch(
    text: "    at Object.<anonymous> (/app/dist/index.js:5:12)",
    column: 30,
    expectPath: "/app/dist/index.js",
    expectLine: 5,
    label: "C4 Node.js stack frame")

// C5. grep -n output
expectMatch(
    text: "/etc/hosts:42:127.0.0.1 localhost",
    column: 5,
    expectPath: "/etc/hosts",
    expectLine: 42,
    label: "C5 grep -n output")

// C6. Rust arrow style, relative path
expectMatch(
    text: "  --> src/main.rs:7:3",
    column: 6,
    expectPath: "src/main.rs",
    expectLine: 7,
    label: "C6 Rust arrow relative path")

// C7. Rust arrow style, absolute path
expectMatch(
    text: "  --> /home/bob/proj/src/lib.rs:120:5",
    column: 8,
    expectPath: "/home/bob/proj/src/lib.rs",
    expectLine: 120,
    label: "C7 Rust arrow absolute path")

// C8. Python traceback
expectMatch(
    text: #"  File "script.py", line 12, in <module>"#,
    column: 8,
    expectPath: "script.py",
    expectLine: 12,
    label: "C8 Python traceback")

// C9. Python traceback with absolute path
expectMatch(
    text: #"  File "/usr/lib/python3/dist-packages/pip/__init__.py", line 9, in <module>"#,
    column: 10,
    expectPath: "/usr/lib/python3/dist-packages/pip/__init__.py",
    expectLine: 9,
    label: "C9 Python traceback absolute path")

// C10. Relative path with subdirectory
expectMatch(
    text: "app/Sources/GoblinPortal/TerminalPane.swift:42:1: warning:",
    column: 20,
    expectPath: "app/Sources/GoblinPortal/TerminalPane.swift",
    expectLine: 42,
    label: "C10 Relative path with subdirectory")

// C11. Closest-to-column selection: two paths in one line, click near second
expectMatch(
    text: "/a/foo.swift:1:1 and /b/bar.swift:99:5",
    column: 25,
    expectPath: "/b/bar.swift",
    expectLine: 99,
    label: "C11 Closest-to-column selection")

// C12. Non-match: plain URL — must NOT be identified as a file path
expectNil(text: "see https://example.com/foo.html for details", column: 10,
          label: "C12 Plain URL not a file path")

// C13. Non-match: plain prose
expectNil(text: "No errors found in the build output.", column: 5,
          label: "C13 Plain prose not a file path")

// C14. Non-match: bare filename with no path separator and no line number
expectNil(text: "main.swift is the entry point", column: 3,
          label: "C14 Bare filename no line number")

// C15. Non-match: number-only tokens
expectNil(text: "exit code 42 from process 7", column: 5,
          label: "C15 Number tokens without path")

// ---- RESOLVE cases ---------------------------------------------------------------

// C16. Absolute path that exists: /usr/bin/env is reliable on macOS
expectResolve(path: "/usr/bin/env", cwd: nil, exists: true, label: "C16 resolve absolute exists")

// C17. Absolute path that does not exist
expectResolve(path: "/nonexistent/path/to/file.swift", cwd: nil, exists: false,
              label: "C17 resolve absolute missing")

// C18. Relative path with cwd: resolve against /usr/bin, look for "env"
expectResolve(path: "env", cwd: URL(fileURLWithPath: "/usr/bin"), exists: true,
              label: "C18 resolve relative with cwd")

print(bad == 0 ? "ALL-OK" : "SOME-FAILED (\(bad) failure(s))")
SWIFT

# ---------------------------------------------------------------------------
# Compile the shipped FilePathDetector.swift with the harness
# ---------------------------------------------------------------------------
if ! swiftc -O -o "$TMP/harness/runner" "$SRC" "$TMP/harness/main.swift" 2>"$TMP/compile.log"; then
    echo "error: $SRC would not compile standalone — the gate cannot run." >&2
    echo "  That file is Foundation-only on purpose so this is possible. If it now needs" >&2
    echo "  AppKit or SwiftTerm, the pure predicate and the live action have been re-merged" >&2
    echo "  and the split that made FilePathDetector.swift checkable is gone." >&2
    sed 's/^/    /' "$TMP/compile.log" >&2
    exit 2
fi

out="$("$TMP/harness/runner" 2>&1)"
if [[ "$out" != *"ALL-OK"* ]]; then
    echo "✗ FAIL: FilePathDetector has incorrect pattern or logic:" >&2
    echo "$out" | sed 's/^/    /' >&2
    exit 1
fi
say "  ok  C1-C11 match cases passed"
say "  ok  C12-C15 non-match cases passed"
say "  ok  C16-C18 resolve cases passed"

# ---------------------------------------------------------------------------
# FALSIFICATION (sourced — check-file-path-detect-falsify.sh)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/check-file-path-detect-falsify.sh"
