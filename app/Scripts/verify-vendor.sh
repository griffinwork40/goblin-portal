#!/bin/bash
#
# Verify the vendored SwiftTerm copy is the revision this app was built against,
# WITH its seven local patches applied.
#
# Why: vendor/ is gitignored, so a re-vendored UNPATCHED tree compiles and runs
# fine while silently corrupting scrollback (0002), bleeding stale cells across
# tmux panes (0003), shipping a release-build abort() (0004), dropping DCS Ptmux
# sequences (0005), and breaking copy/paste (0006, 0007). This script makes that
# silent case loud. Called first by make-app-bundle.sh.
#
# Buffer.swift carries 0002/0003/0004 under ONE combined hash — half-patched
# matches neither and lands in the exit-3 "unknown" branch by design. See the
# pin file (patches/swiftterm/SwiftTerm.pin) for detailed per-patch rationale.
#
# Usage:
#   ./Scripts/verify-vendor.sh            # verify, print one OK line
#   ./Scripts/verify-vendor.sh --quiet    # verify, print nothing on success
#
# Exit codes:
#   0  vendored tree matches the pin
#   1  vendor/ missing, or pin/patch files missing
#   2  present but UNPATCHED (the silent case this script exists to catch) —
#      either Package.swift is missing patch 0001, or Buffer.swift is missing 0002/0003/0004
#   3  present but a hash matches neither patched nor upstream (unknown revision)
#
set -euo pipefail

QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1

# Scripts/ lives in app/; the vendored copy and its patches are at the repo root.
cd "$(dirname "$0")/.."
APP_ROOT="$(pwd)"
REPO_ROOT="$(cd .. && pwd)"

VENDOR="$REPO_ROOT/vendor/SwiftTerm"
PIN="$REPO_ROOT/patches/swiftterm/SwiftTerm.pin"
PATCH="$REPO_ROOT/patches/swiftterm/0001-ship-metal-shader-as-copy-resource.patch"
PATCH_REFLOW="$REPO_ROOT/patches/swiftterm/0002-index-iswrapped-buffer-absolute.patch"
PATCH_ALTSIZE="$REPO_ROOT/patches/swiftterm/0003-trim-lines-on-narrowing-for-all-buffers.patch"
PATCH_DEBUGGATE="$REPO_ROOT/patches/swiftterm/0004-gate-resize-post-condition-behind-debug.patch"
PATCH_PTMUX="$REPO_ROOT/patches/swiftterm/0005-add-dcs-ptmux-passthrough.patch"
PATCH_LFSEL="$REPO_ROOT/patches/swiftterm/0006-gate-linefeed-selection-clear-on-mouse-mode.patch"
PATCH_FEEDSEL="$REPO_ROOT/patches/swiftterm/0007-gate-feedprepare-selection-clear-on-mouse-mode.patch"

say() { [[ "$QUIET" == "1" ]] || echo "$@"; }
err() { echo "$@" >&2; }

# `key = value` out of the pin, tolerating surrounding whitespace. Comments start
# with # and are skipped by the anchored key match.
pin_value() {
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$PIN" | head -1 | tr -d '[:space:]'
}

sha256_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

# --- the pin and patch themselves must be present ------------------------------
for required in "$PIN" "$PATCH" "$PATCH_REFLOW" "$PATCH_ALTSIZE" "$PATCH_DEBUGGATE" "$PATCH_PTMUX" "$PATCH_LFSEL" "$PATCH_FEEDSEL"; do
  if [[ ! -f "$required" ]]; then
    err "error: missing ${required#$REPO_ROOT/}"
    err "       The vendor pin is part of the build contract; do not delete it."
    exit 1
  fi
done

UPSTREAM_REPO="$(pin_value upstream_repo)"
UPSTREAM_TAG="$(pin_value upstream_tag)"
UPSTREAM_COMMIT="$(pin_value upstream_commit)"
WANT_PATCHED="$(pin_value patched_package_swift)"
WANT_UPSTREAM="$(pin_value upstream_package_swift)"
WANT_BUFFER="$(pin_value patched_buffer_swift)"
WANT_BUFFER_UPSTREAM="$(pin_value upstream_buffer_swift)"
WANT_PARSER="$(pin_value patched_escape_seq_parser)"
WANT_PARSER_UPSTREAM="$(pin_value upstream_escape_seq_parser)"
WANT_PTMUX="$(pin_value ptmux_dcs_handler)"
WANT_ATV="$(pin_value patched_apple_terminal_view)"
WANT_ATV_UPSTREAM="$(pin_value upstream_apple_terminal_view)"

# --- vendor/ present? ----------------------------------------------------------
if [[ ! -d "$VENDOR" ]]; then
  err "error: vendor/SwiftTerm is missing."
  err ""
  err "Recreate it:"
  err "  ./Scripts/bootstrap-vendor.sh"
  err ""
  err "That clones $UPSTREAM_TAG, applies all seven patches in order, and re-runs this"
  err "check for the verdict. app/README.md documents the manual equivalent if you"
  err "would rather see the steps than trust a script."
  err ""
  err "ALL SEVEN patches are required. 0002 fixes SwiftTerm #494 (scrollback corruption on"
  err "narrowing), 0003 fixes the alt-buffer resize defect (stale cells bleeding across tmux"
  err "panes on widening), 0004 stops an upstream release-build abort() on every resize, 0005"
  err "adds DCS Ptmux passthrough, 0006 keeps the selection alive during linefeed at a plain"
  err "prompt, and 0007 keeps the selection alive during pty output (feedPrepare);"
  err "check-reflow.sh and check-altbuffer-resize.sh are what prove 0002 and 0003 applied."
  exit 1
fi

if [[ ! -f "$VENDOR/Package.swift" ]]; then
  err "error: vendor/SwiftTerm exists but has no Package.swift — incomplete checkout."
  exit 1
fi

# --- the load-bearing check: is the patch applied? -----------------------------
GOT_PACKAGE="$(sha256_of "$VENDOR/Package.swift")"

if [[ "$GOT_PACKAGE" == "$WANT_UPSTREAM" ]]; then
  err "error: vendor/SwiftTerm is UNPATCHED upstream $UPSTREAM_TAG."
  err ""
  err "Upstream declares Shaders.metal as \`.process\`, which invokes the offline Metal"
  err "compiler. Xcode 26.6 moved that toolchain to a downloadable component"
  err "(\`xcodebuild -downloadComponent MetalToolchain\`), so on a Command Line Tools"
  err "machine the build dies at \`unable to spawn process 'metal'\`. 0001 makes it a"
  err "\`.copy\` instead: the shader ships as source and MetalTerminalRenderer compiles"
  err "it at runtime, which needs no toolchain. Without 0001 you get no build at all;"
  err "with the OLD exclude-based 0001 you got a build with no reachable GPU renderer."
  err ""
  err "Apply the patch:"
  err "  patch -p1 -d vendor/SwiftTerm < patches/swiftterm/0001-ship-metal-shader-as-copy-resource.patch"
  exit 2
fi

if [[ "$GOT_PACKAGE" != "$WANT_PATCHED" ]]; then
  err "error: vendor/SwiftTerm/Package.swift matches neither the pinned patched hash"
  err "       nor upstream $UPSTREAM_TAG. The vendored copy is an unknown revision."
  err ""
  err "  expected (patched): $WANT_PATCHED"
  err "  found:              $GOT_PACKAGE"
  err ""
  err "If you deliberately re-vendored or edited the patch, regenerate the pin:"
  err "  shasum -a 256 vendor/SwiftTerm/Package.swift"
  err "  # then update patched_package_swift in patches/swiftterm/SwiftTerm.pin"
  exit 3
fi

# --- the second load-bearing check: is the reflow patch applied? ----------------
# Same logic as Package.swift above, deliberately mirrored. Buffer.swift carries a
# REQUIRED patch (0002) that fixes the #494 _yBase defect at lines 1171/1211, so
# "changed from the pin" is no longer a curiosity to warn about — an unpatched
# Buffer.swift is a broken build that looks healthy.
BUFFER="$VENDOR/Sources/SwiftTerm/Buffer.swift"
if [[ ! -f "$BUFFER" ]]; then
  err "error: vendor/SwiftTerm has no Sources/SwiftTerm/Buffer.swift — incomplete checkout."
  exit 1
fi

GOT_BUFFER="$(sha256_of "$BUFFER")"

if [[ "$GOT_BUFFER" == "$WANT_BUFFER_UPSTREAM" ]]; then
  err "error: vendor/SwiftTerm/Sources/SwiftTerm/Buffer.swift is UNPATCHED upstream $UPSTREAM_TAG."
  err ""
  err "This tree will COMPILE, RUN, and SILENTLY CORRUPT SCROLLBACK. SwiftTerm #494:"
  err "lines 1171/1211 set \`_lines[_y].isWrapped\` with a SCREEN-relative index while"
  err "the adjacent content writes at 1176/1224 use the BUFFER-absolute"
  err "\`_lines[_y + _yBase]\`, so with non-empty scrollback the wrapped-line flag lands"
  err "on the wrong row and reflow joins/splits unrelated history on every narrowing."
  err ""
  err "Apply the patch:"
  err "  patch -p1 -d vendor/SwiftTerm < patches/swiftterm/0002-index-iswrapped-buffer-absolute.patch"
  err "  patch -p1 -d vendor/SwiftTerm < patches/swiftterm/0003-trim-lines-on-narrowing-for-all-buffers.patch"
  err "  patch -p1 -d vendor/SwiftTerm < patches/swiftterm/0004-gate-resize-post-condition-behind-debug.patch"
  err ""
  err "Then prove they took (each gate was validated by falsification):"
  err "  cd app && ./Scripts/check-reflow.sh            # 6 of 8 fail without 0002"
  err "  cd app && ./Scripts/check-altbuffer-resize.sh  # 2 of 4 fail without 0003"
  exit 2
fi

if [[ "$GOT_BUFFER" != "$WANT_BUFFER" ]]; then
  err "error: vendor/SwiftTerm/Sources/SwiftTerm/Buffer.swift matches neither the pinned"
  err "       patched hash nor upstream $UPSTREAM_TAG. The vendored copy is unknown."
  err ""
  err "  expected (patched): $WANT_BUFFER"
  err "  found:              $GOT_BUFFER"
  err ""
  err "If you deliberately re-vendored or upgraded SwiftTerm: re-check whether the #494"
  err "_yBase defect still exists at lines 1171/1211, whether the line-trim loop is still"
  err "inside 'if isReflowEnabled' near line 522, and whether the '// DEBUG: Post-condition'"
  err "loop after it is still ungated, re-apply or retire 0002/0003/0004, run BOTH gates"
  err "  cd app && ./Scripts/check-reflow.sh && ./Scripts/check-altbuffer-resize.sh"
  err "and only then regenerate the pin:"
  err "  shasum -a 256 vendor/SwiftTerm/Sources/SwiftTerm/Buffer.swift"
  err "  # then update patched_buffer_swift in patches/swiftterm/SwiftTerm.pin"
  exit 3
fi

# --- third load-bearing check: is the ptmux passthrough patch applied? -----------
# 0005 adds PtmuxDcsHandler.swift (new file) and extends dispatchDcs() in
# EscapeSequenceParser.swift. A tree missing 0005 drops DCS Ptmux sequences silently
# — OSC 52 clipboard, graphics, and custom sequences from apps like neovim running
# inside tmux with allow-passthrough=on are lost, with no runtime error or log.
PARSER="$VENDOR/Sources/SwiftTerm/EscapeSequenceParser.swift"
if [[ ! -f "$PARSER" ]]; then
  err "error: vendor/SwiftTerm has no Sources/SwiftTerm/EscapeSequenceParser.swift -- incomplete checkout."
  exit 1
fi

PTMUX_HANDLER="$VENDOR/Sources/SwiftTerm/PtmuxDcsHandler.swift"
if [[ ! -f "$PTMUX_HANDLER" ]]; then
  err "error: vendor/SwiftTerm is missing PtmuxDcsHandler.swift."
  err ""
  err "Patch 0005 adds this file and extends dispatchDcs() in EscapeSequenceParser.swift."
  err "Without it DCS Ptmux sequences (OSC 52 clipboard, graphics, etc.) from apps"
  err "inside tmux are silently dropped."
  err ""
  err "Apply the patch:"
  err "  patch -p1 -d vendor/SwiftTerm < patches/swiftterm/0005-add-dcs-ptmux-passthrough.patch"
  exit 2
fi

GOT_PARSER="$(sha256_of "$PARSER")"

if [[ "$GOT_PARSER" == "$WANT_PARSER_UPSTREAM" ]]; then
  err "error: vendor/SwiftTerm/Sources/SwiftTerm/EscapeSequenceParser.swift is UNPATCHED upstream $UPSTREAM_TAG."
  err ""
  err "Patch 0005 adds a PtmuxDcsHandler branch to dispatchDcs() so that DCS Ptmux"
  err "passthrough sequences (ESC P tmux;...) are decoded and re-fed to the terminal."
  err "Without it, apps like neovim inside tmux with allow-passthrough=on lose all"
  err "passthrough sequences silently."
  err ""
  err "Apply the patch:"
  err "  patch -p1 -d vendor/SwiftTerm < patches/swiftterm/0005-add-dcs-ptmux-passthrough.patch"
  exit 2
fi

if [[ "$GOT_PARSER" != "$WANT_PARSER" ]]; then
  err "error: vendor/SwiftTerm/Sources/SwiftTerm/EscapeSequenceParser.swift matches neither"
  err "       the pinned patched hash nor upstream $UPSTREAM_TAG. The vendored copy is unknown."
  err ""
  err "  expected (patched): $WANT_PARSER"
  err "  found:              $GOT_PARSER"
  err ""
  err "If you deliberately re-vendored or edited the patch, regenerate the pin:"
  err "  shasum -a 256 vendor/SwiftTerm/Sources/SwiftTerm/EscapeSequenceParser.swift"
  err "  # then update patched_escape_seq_parser in patches/swiftterm/SwiftTerm.pin"
  exit 3
fi

# --- third-b check: is PtmuxDcsHandler.swift the expected file? ----------------
# 0005 adds this file new; there is no upstream counterpart. The existence check
# above catches a missing file (compile error), but a modified file would slip
# through without this hash check.
GOT_PTMUX="$(sha256_of "$PTMUX_HANDLER")"

if [[ "$GOT_PTMUX" != "$WANT_PTMUX" ]]; then
  err "error: vendor/SwiftTerm/Sources/SwiftTerm/PtmuxDcsHandler.swift does not match"
  err "       the pinned hash. The file may have been edited or came from a different"
  err "       version of the patch."
  err ""
  err "  expected: $WANT_PTMUX"
  err "  found:    $GOT_PTMUX"
  err ""
  err "If you deliberately re-vendored or edited the patch, regenerate the pin:"
  err "  shasum -a 256 vendor/SwiftTerm/Sources/SwiftTerm/PtmuxDcsHandler.swift"
  err "  # then update ptmux_dcs_handler in patches/swiftterm/SwiftTerm.pin"
  exit 3
fi

# --- fourth check: is the linefeed selection-clear patch applied? ---------------
# 0006 gates linefeed's selection.selectNone() on terminal.mouseMode != .off so
# that a plain shell prompt (mouseMode == .off) preserves the selection during
# streaming output. Without it, every LF clears the selection before ⌘C fires.
MTV="$VENDOR/Sources/SwiftTerm/Mac/MacTerminalView.swift"
if [[ ! -f "$MTV" ]]; then
  err "error: vendor/SwiftTerm has no Sources/SwiftTerm/Mac/MacTerminalView.swift -- incomplete checkout."
  exit 1
fi

WANT_MTV="$(pin_value patched_mac_terminal_view)"
WANT_MTV_UPSTREAM="$(pin_value upstream_mac_terminal_view)"
GOT_MTV="$(sha256_of "$MTV")"

if [[ "$GOT_MTV" == "$WANT_MTV_UPSTREAM" ]]; then
  err "error: vendor/SwiftTerm/Sources/SwiftTerm/Mac/MacTerminalView.swift is UNPATCHED upstream $UPSTREAM_TAG."
  err ""
  err "Patch 0006 gates linefeed(source:)'s selection.selectNone() on"
  err "terminal.mouseMode != .off. Without it, every newline in the terminal output"
  err "clears the user's text selection — copy/paste feels broken even though ⌘C"
  err "itself works correctly."
  err ""
  err "Apply the patch:"
  err "  patch -p1 -d vendor/SwiftTerm < patches/swiftterm/0006-gate-linefeed-selection-clear-on-mouse-mode.patch"
  exit 2
fi

if [[ "$GOT_MTV" != "$WANT_MTV" ]]; then
  err "error: vendor/SwiftTerm/Sources/SwiftTerm/Mac/MacTerminalView.swift matches neither"
  err "       the pinned patched hash nor upstream $UPSTREAM_TAG. The vendored copy is unknown."
  err ""
  err "  expected (patched): $WANT_MTV"
  err "  found:              $GOT_MTV"
  err ""
  err "If you deliberately re-vendored or edited the patch, regenerate the pin:"
  err "  shasum -a 256 vendor/SwiftTerm/Sources/SwiftTerm/Mac/MacTerminalView.swift"
  err "  # then update patched_mac_terminal_view in patches/swiftterm/SwiftTerm.pin"
  exit 3
fi

# --- fifth check: is the feedPrepare selection-clear patch applied? ----------------
# 0007 gates feedPrepare()'s selection.active = false on terminal.mouseMode != .off
# so that pty output at a plain prompt (mouseMode == .off) preserves the selection.
# Without it, ANY output between selecting text and pressing ⌘C clears the selection,
# causing validateUserInterfaceItem to disable Copy and silently swallow the keystroke.
# Same defect pattern as 0006 (linefeed), different call site (feedPrepare).
ATV="$VENDOR/Sources/SwiftTerm/Apple/AppleTerminalView.swift"
if [[ ! -f "$ATV" ]]; then
  err "error: vendor/SwiftTerm has no Sources/SwiftTerm/Apple/AppleTerminalView.swift -- incomplete checkout."
  exit 1
fi

GOT_ATV="$(sha256_of "$ATV")"

if [[ "$GOT_ATV" == "$WANT_ATV_UPSTREAM" ]]; then
  err "error: vendor/SwiftTerm/Sources/SwiftTerm/Apple/AppleTerminalView.swift is UNPATCHED upstream $UPSTREAM_TAG."
  err ""
  err "Patch 0007 gates feedPrepare()'s selection.active = false on"
  err "terminal.mouseMode != .off. Without it, any pty output between selecting"
  err "text and pressing ⌘C clears the selection — copy/paste is silently broken."
  err ""
  err "Apply the patch:"
  err "  patch -p1 -d vendor/SwiftTerm < patches/swiftterm/0007-gate-feedprepare-selection-clear-on-mouse-mode.patch"
  exit 2
fi

if [[ "$GOT_ATV" != "$WANT_ATV" ]]; then
  err "error: vendor/SwiftTerm/Sources/SwiftTerm/Apple/AppleTerminalView.swift matches neither"
  err "       the pinned patched hash nor upstream $UPSTREAM_TAG. The vendored copy is unknown."
  err ""
  err "  expected (patched): $WANT_ATV"
  err "  found:              $GOT_ATV"
  err ""
  err "If you deliberately re-vendored or edited the patch, regenerate the pin:"
  err "  shasum -a 256 vendor/SwiftTerm/Sources/SwiftTerm/Apple/AppleTerminalView.swift"
  err "  # then update patched_apple_terminal_view in patches/swiftterm/SwiftTerm.pin"
  exit 3
fi

# --- sixth check: is the search-state-changed hook (0009) applied? ---------------
TVS="$VENDOR/Sources/SwiftTerm/TerminalViewSearch.swift"
if [ ! -f "$TVS" ]; then err "error: TerminalViewSearch.swift missing."; exit 1; fi
WANT_TVS="$(pin_value patched_terminal_view_search)"
GOT_TVS="$(sha256_of "$TVS")"
if [ "$GOT_TVS" != "$WANT_TVS" ]; then
  err "error: TerminalViewSearch.swift hash mismatch (expected $WANT_TVS, got $GOT_TVS)."
  err "  Regenerate: shasum -a 256 $TVS"
  exit 3
fi

say "==> vendor OK: SwiftTerm $UPSTREAM_TAG (${UPSTREAM_COMMIT:0:7}) + 9 local patches"
