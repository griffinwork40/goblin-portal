#!/bin/bash
#
# Verify the vendored SwiftTerm copy is the revision this app was built against,
# WITH its fifteen local patches applied (re-vendor 2026-10-27, upstream c3436be).
#
# Why: vendor/ is gitignored, so a re-vendored UNPATCHED tree compiles and runs
# fine while silently corrupting behaviour. This script makes that loud.
# Patches 0001-0015 (renumbered from v1.15.0's 0001-0019, plus two new additions):
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
#   0014 ProMotion immediate-draw: isImmediate path in frameTick/submitFrameDraw
#   0015 fullscreen Space transition observers in FrameDriver (fixes #302)
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

# --- patch-set consistency check ---------------------------------------------
# The number and names of *.patch files on disk must match exactly what
# bootstrap-vendor.sh applies. A mismatch here means someone added or removed a
# patch file without updating the other script, which produces a vendor/ tree that
# does not match what this script expects.
#
# PATCH_DIR can be overridden for falsification testing:
#   PATCH_DIR=/some/tmp/dir ./Scripts/verify-vendor.sh
# The real tree uses the default (repo root patches/swiftterm/).
PATCH_DIR="${PATCH_DIR:-$REPO_ROOT/patches/swiftterm}"

# The authoritative list comes from bootstrap-vendor.sh. We extract it with awk
# so the two scripts cannot silently diverge: there is one source of truth.
BOOTSTRAP="$APP_ROOT/Scripts/bootstrap-vendor.sh"
if [[ ! -f "$BOOTSTRAP" ]]; then
  err "error: Scripts/bootstrap-vendor.sh not found; cannot verify patch-set consistency."
  exit 1
fi

# Extract the patch filenames from the PATCHES=(...) array in bootstrap-vendor.sh.
# awk reads lines between the opening ( and the closing ) of that array.
# Using a while-read loop instead of mapfile: macOS ships bash 3.2, which lacks mapfile.
EXPECTED_PATCHES=()
while IFS= read -r line; do
  EXPECTED_PATCHES+=("$line")
done < <(awk '/^PATCHES=\(/{p=1; next} p && /\)/{p=0} p{gsub(/^[[:space:]"]+|["[:space:]]+$/, ""); if (NF) print}' "$BOOTSTRAP")

# Collect patch files actually on disk in PATCH_DIR (sorted for stable comparison).
DISK_PATCHES=()
while IFS= read -r line; do
  DISK_PATCHES+=("$line")
done < <(find "$PATCH_DIR" -maxdepth 1 -name '*.patch' -exec basename {} \; | sort)

PATCH_COUNT="${#DISK_PATCHES[@]}"
EXPECTED_COUNT="${#EXPECTED_PATCHES[@]}"

# Check for files on disk that bootstrap does not apply.
for f in "${DISK_PATCHES[@]}"; do
  found=0
  for e in "${EXPECTED_PATCHES[@]}"; do [[ "$e" == "$f" ]] && found=1 && break; done
  if [[ "$found" == "0" ]]; then
    err "error: patch file '$f' exists in patches/swiftterm/ but is not in bootstrap-vendor.sh's PATCHES list."
    err "       Add it to PATCHES in bootstrap-vendor.sh, or remove it from patches/swiftterm/."
    exit 1
  fi
done

# Check for files bootstrap expects that are missing from disk.
for e in "${EXPECTED_PATCHES[@]}"; do
  if [[ ! -f "$PATCH_DIR/$e" ]]; then
    err "error: bootstrap-vendor.sh lists '$e' but that file is missing from patches/swiftterm/."
    err "       Restore the patch file, or remove it from PATCHES in bootstrap-vendor.sh."
    exit 1
  fi
done

if [[ "$PATCH_COUNT" != "$EXPECTED_COUNT" ]]; then
  err "error: patch count mismatch: $PATCH_COUNT files on disk, $EXPECTED_COUNT listed in bootstrap-vendor.sh."
  exit 1
fi

# --- vendor/ present? ----------------------------------------------------------
if [[ ! -d "$VENDOR" ]]; then
  err "error: vendor/SwiftTerm is missing."
  err ""
  err "Recreate it (clones upstream c3436be and applies $PATCH_COUNT patches):"
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

say "==> vendor OK: SwiftTerm $UPSTREAM_TAG (${UPSTREAM_COMMIT:0:7}) + $PATCH_COUNT local patches"
