# Sourced by verify-vendor.sh — never run on its own. The VIEW-LAYER half of the vendor
# verdict: every check on the files patches 0006-0011 touch (MacTerminalView.swift,
# AppleTerminalView.swift, TerminalViewSearch.swift, MacDisplayLinkPacer.swift,
# Apple/Metal/MetalTerminalRenderer.swift).
#
# Split out of verify-vendor.sh when 0010 pushed it past the 350-line ceiling. The seam
# is the file layer: verify-vendor.sh keeps the pin plumbing and the model/parser checks
# (Package.swift, Buffer.swift, Terminal.swift, the escape parser); this file owns the
# view files. It inherits VENDOR, UPSTREAM_TAG, WANT_ATV, WANT_ATV_UPSTREAM and the
# pin_value / sha256_of / err / say helpers from its caller, and its `exit`s are the
# caller's exits — the exit-code contract is verify-vendor.sh's, unchanged.

# --- 0010 first: is the display-link pacer present? --------------------------------
# Checked BEFORE the MacTerminalView/AppleTerminalView hashes on purpose: a tree
# bootstrapped with 0001-0009 only also fails those two hashes, but as an anonymous
# "unknown revision" (exit 3). Missing the pacer's own file is the one symptom that NAMES
# the cause, so it is reported first. Severity: SILENT — a tree without 0010 builds and
# runs, and paints on upstream's free-running 16.67ms timer, which drops every other
# frame of a 60fps producer and lands the rest at a drifting vsync phase.
PACER="$VENDOR/Sources/SwiftTerm/Mac/MacDisplayLinkPacer.swift"
if [[ ! -f "$PACER" ]]; then
  err "error: vendor/SwiftTerm has no Sources/SwiftTerm/Mac/MacDisplayLinkPacer.swift."
  err ""
  err "Patch 0010 is not applied. The tree builds, but redraws run on upstream's"
  err "free-running timer: a 60fps producer (an ink reveal through tmux) paints at ~30fps"
  err "and at an uneven phase of the display refresh. check-display-link.sh is the gate."
  err ""
  err "Apply the patch:"
  err "  patch -p1 -d vendor/SwiftTerm < patches/swiftterm/0010-pace-redraws-on-display-link.patch"
  exit 2
fi
WANT_PACER="$(pin_value mac_display_link_pacer)"
GOT_PACER="$(sha256_of "$PACER")"
if [[ "$GOT_PACER" != "$WANT_PACER" ]]; then
  err "error: vendor/SwiftTerm/Sources/SwiftTerm/Mac/MacDisplayLinkPacer.swift does not match"
  err "       the pinned hash. The file was edited or came from a different version of 0010."
  err ""
  err "  expected: $WANT_PACER"
  err "  found:    $GOT_PACER"
  err ""
  err "If you deliberately edited the patch, regenerate the pin:"
  err "  shasum -a 256 vendor/SwiftTerm/Sources/SwiftTerm/Mac/MacDisplayLinkPacer.swift"
  err "  # then update mac_display_link_pacer in patches/swiftterm/SwiftTerm.pin"
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

# --- seventh check: are blank-glyph misses cached (0011)? -------------------------
# Severity: SILENT. Without 0011 the Metal renderer draws identically but re-asks
# CoreText (CTFontGetBoundingRectsForGlyphs) about every blank cell on every row
# rebuild, so a pane showing only an agent spinner burns CPU it never needed.
MTR="$VENDOR/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift"
if [ ! -f "$MTR" ]; then err "error: Apple/Metal/MetalTerminalRenderer.swift missing."; exit 1; fi
GOT_MTR="$(sha256_of "$MTR")"
if [ "$GOT_MTR" == "$(pin_value upstream_metal_terminal_renderer)" ]; then
  err "error: Apple/Metal/MetalTerminalRenderer.swift is UNPATCHED upstream $UPSTREAM_TAG."
  err "Patch 0011 caches blank-glyph rasterizer misses; without it idle spinner panes burn CPU."
  err "  patch -p1 -d vendor/SwiftTerm < patches/swiftterm/0011-cache-empty-glyphs-and-font-names.patch"
  exit 2
fi
if [ "$GOT_MTR" != "$(pin_value patched_metal_terminal_renderer)" ]; then
  err "error: MetalTerminalRenderer.swift hash mismatch (got $GOT_MTR)."
  err "  Regenerate: shasum -a 256 $MTR  # then update patched_metal_terminal_renderer"
  exit 3
fi
