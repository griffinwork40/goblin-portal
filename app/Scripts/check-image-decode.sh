#!/bin/bash
#
# check-image-decode.sh — patches 0018/0019/0020: are inline-image payloads (incl. sixel) bounded, and does
# OSC 1337 multipart (modern imgcat) render through the same bounded path?
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
# A trap (e.g. SixelDcsHandler Index out of range, #280) kills the harness. The 0020 cases
# print "BEGIN <case>" before running, so a death whose last marker is a BEGIN is a
# real failure in that named case (exit 1; under --falsify it counts only for the
# mutant's declared case). A death with no marker as its last line stays environmental.
#
# Exit: 0 pass, 1 assertion failure (or a mutant survived), 2 environmental.
set -uo pipefail
cd "$(dirname "$0")/.."
APP_ROOT="$(pwd)"; REPO_ROOT="$(cd .. && pwd)"
HARNESS="$APP_ROOT/Scripts/check-image-decode-harness.swift"
MULTIPART="$APP_ROOT/Scripts/check-image-decode-multipart.swift"
SIXEL="$APP_ROOT/Scripts/check-image-decode-sixel.swift"
# Verbatim stdout of the real modern imgcat (iterm2.com/utilities/imgcat) on a 16x16 PNG.
export IMAGE_DECODE_FIXTURE="$APP_ROOT/Scripts/fixtures/imgcat-multipart-16x16.bin"
say() { echo "$@"; }
[[ -d "$REPO_ROOT/vendor/SwiftTerm" ]] || { echo "error: vendor/ missing — run bootstrap-vendor.sh" >&2; exit 2; }
command -v swiftc >/dev/null 2>&1 || { echo "error: swiftc not found" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# build_and_run <app-dir> <out-bin> [case]: builds SwiftTerm in <app-dir>, compiles, runs.
build_bin() {
  local dir="$1" bin="$2"
  (cd "$dir" && . Scripts/vendored-module.sh && resolve_vendored_module >/dev/null && echo "$PRODUCTS" >"$TMP/products") || return 2
  local P; P="$(cat "$TMP/products")"
  cp "$HARNESS" "$TMP/main.swift"; cp "$MULTIPART" "$TMP/multipart.swift"; cp "$SIXEL" "$TMP/sixel.swift"
  swiftc -O -o "$bin" "$TMP/main.swift" "$TMP/multipart.swift" "$TMP/sixel.swift" -I "$P" -L "$P" "$P/SwiftTerm.o" -framework AppKit \
    2>"$TMP/compile.log" || { sed 's/^/  /' "$TMP/compile.log" >&2; return 2; }
}

# crashed_case <out>: the case name when the last BEGIN/PASS/FAIL line is a BEGIN marker
# (that case started and never reported), else "". The runtime's own trap message lands
# after it on stderr, so the marker is not necessarily the very last line.
crashed_case() { local l; l="$(grep -E '^(BEGIN|PASS|FAIL) ' "$1" | tail -n 1)"; [[ "$l" == "BEGIN "* ]] && echo "${l#BEGIN }"; true; }

if [[ "${1:-}" != "--falsify" ]]; then
  build_bin "$APP_ROOT" "$TMP/imgdecode" || { echo "error: build/compile failed (environmental)" >&2; exit 2; }
  "$TMP/imgdecode" | tee "$TMP/out"; rc=${PIPESTATUS[0]}
  case "$rc" in 0) say "check-image-decode: all cases PASS";; 1) say "check-image-decode: FAIL"; exit 1;;
    *) died="$(crashed_case "$TMP/out")"
       if [[ -n "$died" ]]; then say "FAIL $died: harness died inside this case (rc=$rc)"; exit 1; fi
       echo "error: harness crashed outside any marked case (rc=$rc)" >&2; exit 2;; esac
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
  # 0019 mutants
  "cap-per-part|Terminal.swift|s{if transfer.encoded.count \\+ part.count > }{if part.count > }|multipart-overcap"
  "fileend-unrouted|Terminal.swift|s{insertInlineImage \\(transfer.params, transfer.encoded\\[...\\], dimension: parseDimension\\)}{_ = transfer.params}|multipart-3part"
  "inline0-buffered|Terminal.swift|s{kv\\[\\x22inline\\x22\\] == \\x221\\x22 \\? ITermMultipartTransfer\\(params: kv\\) : nil}{ITermMultipartTransfer(params: kv)}|multipart-inline0"
  "reset-keeps-state|Terminal.swift|s{iTermMultipart = nil  // PATCH 0019: RIS}{// RIS}|multipart-reset"
  # #283 inactivity release: the watchdog never armed / FilePart never refreshes the stamp
  "no-stale-watchdog|Terminal.swift|s{if iTermMultipart != nil \\{ armITermMultipartWatchdog \\(after: iTermMultipartInactivitySeconds\\) \\}}{}|multipart-stale"
  "part-not-stamped|Terminal.swift|s{transfer.lastActivity = DispatchTime.now\\(\\)  // #283}{// #283}|multipart-slow-alive"
  # 0020 mutants (#280). The first two restore upstream's TRAP: caught only as a death in
  # the declared case. sixel-short-buffer has no mutant: removing 0018's bytes.count guard
  # is equivalent (CGImage itself rejects a short provider) — see the case comment.
  "open-band-fold|SixelDcsHandler.swift|s{maxX = max\\(maxX, x\\)\\n\\s*guard !oversize, maxX > 0, maxY > 0 else}{guard !oversize else}|sixel-unclosed"
  "number-saturate|SixelDcsHandler.swift|s{min\\(10 \\* existing \\+ digit, SixelDcsHandler.maximumSide \\+ 1\\)}{10 * existing + digit}|sixel-overflow"
  "side-bound|SixelDcsHandler.swift|s{guard reps <= SixelDcsHandler.maximumSide - x, y <= SixelDcsHandler.maximumSide - 6 else}{guard true else}|sixel-oversize"
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
  elif [[ $rc -gt 1 && "$(crashed_case "$R/out")" == "$kase" ]]; then
    say "    CAUGHT (died inside declared case $kase, rc=$rc)"; CAUGHT=$((CAUGHT+1))
  else say "    MISSED (rc=$rc)"; sed 's/^/      /' "$R/out"; MISSED=$((MISSED+1)); fi
  rm -rf "$R"
done
[[ $RAN -gt 0 ]] || { echo "error: zero mutants ran" >&2; exit 2; }
say "FALSIFY: $CAUGHT/$RAN mutants caught"
[[ $MISSED -eq 0 ]] || exit 1
exit 0
