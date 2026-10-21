#!/bin/bash
#
# check-image-decode.sh — patch 0018: are inline-image payloads bounded?
#
# Headless-ish: links the vendored SwiftTerm.o and drives a real TerminalView (an NSView
# that is never put in a window — AppKit is linked, no window server is required).
# Assertions live in check-image-decode-harness.swift (350-LOC split).
#
# --falsify: APFS-clones app/ and vendor/ to a temp dir, removes ONE guard per mutant in
# the COPY of shipped vendor source, rebuilds, and re-runs ONLY the mutant's declared
# case. A mutant counts only when that case fails (exit 1). Pattern miss / compile
# failure => exit 2. Zero mutants run => exit 2.
#
# Exit: 0 pass, 1 assertion failure (or a mutant survived), 2 environmental.
set -uo pipefail
cd "$(dirname "$0")/.."
APP_ROOT="$(pwd)"; REPO_ROOT="$(cd .. && pwd)"
HARNESS="$APP_ROOT/Scripts/check-image-decode-harness.swift"
say() { echo "$@"; }
[[ -d "$REPO_ROOT/vendor/SwiftTerm" ]] || { echo "error: vendor/ missing — run bootstrap-vendor.sh" >&2; exit 2; }
command -v swiftc >/dev/null 2>&1 || { echo "error: swiftc not found" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# build_and_run <app-dir> <out-bin> [case]: builds SwiftTerm in <app-dir>, compiles, runs.
build_bin() {
  local dir="$1" bin="$2"
  (cd "$dir" && . Scripts/vendored-module.sh && resolve_vendored_module >/dev/null && echo "$PRODUCTS" >"$TMP/products") || return 2
  local P; P="$(cat "$TMP/products")"
  cp "$HARNESS" "$TMP/main.swift"
  swiftc -O -o "$bin" "$TMP/main.swift" -I "$P" -L "$P" "$P/SwiftTerm.o" -framework AppKit \
    2>"$TMP/compile.log" || { sed 's/^/  /' "$TMP/compile.log" >&2; return 2; }
}

if [[ "${1:-}" != "--falsify" ]]; then
  build_bin "$APP_ROOT" "$TMP/imgdecode" || { echo "error: build/compile failed (environmental)" >&2; exit 2; }
  "$TMP/imgdecode"; rc=$?
  case "$rc" in 0) say "check-image-decode: all cases PASS";; 1) say "check-image-decode: FAIL"; exit 1;; *) echo "error: harness crashed (rc=$rc)" >&2; exit 2;; esac
  exit 0
fi

# --- falsification -------------------------------------------------------------
# mutant table: name | file (rel. to Sources/SwiftTerm) | perl substitution | declared case
MUTANTS=(
  "osc-cap|EscapeSequenceParser.swift|s{\\} else if osc.count < EscapeSequenceParser.maximumOscBytes \\{}{\\} else if true \\{}|osc-overlimit"
  "encoded-cap|Terminal.swift|s{guard data.endIndex - \\(colonIdx\\+1\\) <= Terminal.maximumInlineImageEncodedBytes else}{guard true else}|oversize-encoded"
  "type-allowlist|Apple/AppleTerminalView.swift|s{TerminalView.inlineImageTypes.contains\\(type\\),}{type.count > 0,}|type-allowlist"
  "pdf-header|Apple/AppleTerminalView.swift|s{guard let src = CGImageSourceCreateWithData\\(data as CFData, nil\\),.*?w > 0, h > 0, max\\(w, h\\) <= TerminalView.maximumInlineImageSide else \\{\\s*return\\s*\\}}{}s|pdf-rejected"
  "dimension-cap|Apple/AppleTerminalView.swift|s{max\\(w, h\\) <= TerminalView.maximumInlineImageSide else}{true else}|dimension-cap"
)
RAN=0; CAUGHT=0; MISSED=0
for m in "${MUTANTS[@]}"; do
  IFS='|' read -r name file sub kase <<<"$m"
  R="$TMP/m-$name"; mkdir -p "$R"
  cp -cR "$APP_ROOT" "$R/app" 2>/dev/null || cp -R "$APP_ROOT" "$R/app"
  rm -rf "$R/app/.build"
  cp -cR "$REPO_ROOT/vendor" "$R/vendor" 2>/dev/null || cp -R "$REPO_ROOT/vendor" "$R/vendor"
  F="$R/vendor/SwiftTerm/Sources/SwiftTerm/$file"; chmod u+w "$F"
  hits="$(SUB="$sub" perl -0777 -i -pe 'BEGIN{$n=0} $n += eval "$ENV{SUB}"; END{print STDERR $n+0}' "$F" 2>&1 >/dev/null)"
  [[ "$hits" == "1" ]] || { echo "error: mutant $name matched $hits (want 1) — pattern stale" >&2; exit 2; }
  say "==> mutant $name (declared case: $kase): building…"
  build_bin "$R/app" "$R/bin" || { echo "error: mutant $name did not build/compile" >&2; exit 2; }
  RAN=$((RAN+1))
  IMAGE_DECODE_ONLY="$kase" "$R/bin" >"$R/out" 2>&1; rc=$?
  if [[ $rc -eq 1 ]] && grep -q "^FAIL $kase" "$R/out"; then say "    CAUGHT ($(grep "^FAIL" "$R/out"))"; CAUGHT=$((CAUGHT+1))
  else say "    MISSED (rc=$rc)"; sed 's/^/      /' "$R/out"; MISSED=$((MISSED+1)); fi
  rm -rf "$R"
done
[[ $RAN -gt 0 ]] || { echo "error: zero mutants ran" >&2; exit 2; }
say "FALSIFY: $CAUGHT/$RAN mutants caught"
[[ $MISSED -eq 0 ]] || exit 1
exit 0
