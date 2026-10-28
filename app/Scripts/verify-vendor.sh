#!/bin/bash
#
# Verify the vendored SwiftTerm copy is the revision this app was built against,
# WITH its thirteen local patches applied (re-vendor 2026-10-27, upstream c3436be).
#
# Why: vendor/ is gitignored, so a re-vendored UNPATCHED tree compiles and runs
# fine while silently corrupting behaviour. This script makes that loud.
# Patches 0001-0013 (renumbered from v1.15.0's 0001-0019):
#   0001 Metal shader as .copy (was 0001)
#   0002 alt-buffer narrowing trim (was 0003)
#   0003 #if DEBUG resize guard (was 0004)
#   0004 DCS Ptmux passthrough (was 0005)
#   0005 draw() open (was 0008)
#   0006 search-state hook (was 0009)
#   0007 colour emoji logical-size rasterizer (was 0012)
#   0008 disable-ligatures both renderers (was 0014)
#   0009 proportional scrollbar thumb (was 0015)
#   0010 adaptive idle-pause in FrameDriver (was 0016, ported from MacDisplayLinkPacer)
#   0011 xtVersion host override + mode 2027 (was 0017 partial)
#   0012 bound inline-image payloads (was 0018 partial — OSC cap already upstream)
#   0013 OSC 1337 multipart (was 0019)
# Dropped (ALREADY-UPSTREAM or OBSOLETE post-IO-rewrite):
#   0002 (isWrapped), 0006/0007 (selection-clear), 0010 (MacDisplayLinkPacer),
#   0011 (empty-glyph cache), 0013 (combining-mark), 0020 (sixel bounds)
#
# Usage:
#   ./Scripts/verify-vendor.sh            # verify, print one OK line
#   ./Scripts/verify-vendor.sh --quiet    # verify, print nothing on success
#
# Exit codes:
#   0  vendored tree matches the pin
#   1  vendor/ missing, or pin/patch files missing
#   2  present but UNPATCHED (the silent case this script exists to catch)
#   3  present but a hash matches neither patched nor upstream (unknown revision)
#
set -euo pipefail

QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1

cd "$(dirname "$0")/.."
APP_ROOT="$(pwd)"
REPO_ROOT="$(cd .. && pwd)"

VENDOR="$REPO_ROOT/vendor/SwiftTerm"
PIN="$REPO_ROOT/patches/swiftterm/SwiftTerm.pin"

say() { [[ "$QUIET" == "1" ]] || echo "$@"; }
err() { echo "$@" >&2; }

pin_value() {
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$PIN" | head -1 | tr -d '[:space:]'
}

sha256_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

# --- pin must be present -------------------------------------------------------
if [[ ! -f "$PIN" ]]; then
  err "error: missing patches/swiftterm/SwiftTerm.pin"
  err "       The vendor pin is part of the build contract; do not delete it."
  exit 1
fi

UPSTREAM_COMMIT="$(pin_value upstream_commit)"
UPSTREAM_TAG="$(pin_value upstream_tag)"

# --- vendor/ present? ----------------------------------------------------------
if [[ ! -d "$VENDOR" ]]; then
  err "error: vendor/SwiftTerm is missing."
  err ""
  err "Recreate it (clones upstream c3436be and applies 13 patches):"
  err "  ./Scripts/bootstrap-vendor.sh"
  exit 1
fi

if [[ ! -f "$VENDOR/Package.swift" ]]; then
  err "error: vendor/SwiftTerm exists but has no Package.swift — incomplete checkout."
  exit 1
fi

# --- Package.swift (patch 0001) -----------------------------------------------
GOT_PKG="$(sha256_of "$VENDOR/Package.swift")"
WANT_PKG="$(pin_value patched_package_swift)"
WANT_PKG_UP="$(pin_value upstream_package_swift)"

if [[ "$GOT_PKG" == "$WANT_PKG_UP" ]]; then
  err "error: vendor/SwiftTerm/Package.swift is UNPATCHED upstream $UPSTREAM_COMMIT."
  err "Patch 0001 moves Shaders.metal from exclude: to resources: .copy"
  err "  patch -p1 -d vendor/SwiftTerm < patches/swiftterm/0001-ship-metal-shader-as-copy-resource.patch"
  exit 2
fi
if [[ "$GOT_PKG" != "$WANT_PKG" ]]; then
  err "error: Package.swift hash mismatch. expected=$WANT_PKG got=$GOT_PKG"
  err "  Regenerate: shasum -a 256 vendor/SwiftTerm/Package.swift"
  exit 3
fi

# --- Buffer.swift (patches 0002+0003) -----------------------------------------
BUFFER="$VENDOR/Sources/SwiftTerm/Buffer.swift"
if [[ ! -f "$BUFFER" ]]; then err "error: Buffer.swift missing."; exit 1; fi
GOT_BUF="$(sha256_of "$BUFFER")"
WANT_BUF="$(pin_value patched_buffer_swift)"
WANT_BUF_UP="$(pin_value upstream_buffer_swift)"
if [[ "$GOT_BUF" == "$WANT_BUF_UP" ]]; then
  err "error: Buffer.swift is UNPATCHED upstream. Patches 0002+0003 are required."
  exit 2
fi
if [[ "$GOT_BUF" != "$WANT_BUF" ]]; then
  err "error: Buffer.swift hash mismatch. expected=$WANT_BUF got=$GOT_BUF"
  exit 3
fi

# --- EscapeSequenceParser.swift (patch 0004) ----------------------------------
PARSER="$VENDOR/Sources/SwiftTerm/EscapeSequenceParser.swift"
if [[ ! -f "$PARSER" ]]; then err "error: EscapeSequenceParser.swift missing."; exit 1; fi
PTMUX="$VENDOR/Sources/SwiftTerm/PtmuxDcsHandler.swift"
if [[ ! -f "$PTMUX" ]]; then
  err "error: PtmuxDcsHandler.swift missing — patch 0004 not applied."
  exit 2
fi
GOT_PARSER="$(sha256_of "$PARSER")"
WANT_PARSER="$(pin_value patched_escape_seq_parser)"
WANT_PARSER_UP="$(pin_value upstream_escape_seq_parser)"
if [[ "$GOT_PARSER" == "$WANT_PARSER_UP" ]]; then
  err "error: EscapeSequenceParser.swift is UNPATCHED upstream."
  exit 2
fi
if [[ "$GOT_PARSER" != "$WANT_PARSER" ]]; then
  err "error: EscapeSequenceParser.swift hash mismatch. expected=$WANT_PARSER got=$GOT_PARSER"
  exit 3
fi
GOT_PTMUX="$(sha256_of "$PTMUX")"
if [[ "$GOT_PTMUX" != "$(pin_value ptmux_dcs_handler)" ]]; then
  err "error: PtmuxDcsHandler.swift hash mismatch."
  exit 3
fi

# --- Terminal.swift (patches 0011+0012+0013) ----------------------------------
TERMINAL="$VENDOR/Sources/SwiftTerm/Terminal.swift"
if [[ ! -f "$TERMINAL" ]]; then err "error: Terminal.swift missing."; exit 1; fi
GOT_TERMINAL="$(sha256_of "$TERMINAL")"
if [[ "$GOT_TERMINAL" != "$(pin_value terminal_swift)" ]]; then
  err "error: Terminal.swift hash mismatch (patches 0011+0012+0013)."
  err "  expected: $(pin_value terminal_swift)"
  err "  found:    $GOT_TERMINAL"
  exit 3
fi

# --- marker checks: 0012 image guards -----------------------------------------
for marker in "Terminal.swift:maximumInlineImageEncodedBytes" \
              "Apple/AppleTerminalView.swift:inlineImageTypes.contains"; do
  if ! grep -q "${marker#*:}" "$VENDOR/Sources/SwiftTerm/${marker%%:*}"; then
    err "error: patch 0012 is not applied (${marker%%:*} lacks ${marker#*:})."
    exit 2
  fi
done

# --- marker checks: 0013 multipart --------------------------------------------
for marker in "case \"MultipartFile\":" "case \"FilePart\":" "iTermMultipart = nil"; do
  if ! grep -qF "$marker" "$VENDOR/Sources/SwiftTerm/Terminal.swift"; then
    err "error: patch 0013 is not applied (Terminal.swift lacks $marker)."
    exit 2
  fi
done

# --- view-layer checks live in verify-vendor-views.sh -------------------------
. "$APP_ROOT/Scripts/verify-vendor-views.sh"

say "==> vendor OK: SwiftTerm $UPSTREAM_TAG (${UPSTREAM_COMMIT:0:7}) + 13 local patches"
