# Sourced by verify-vendor.sh — never run on its own. The VIEW-LAYER half of the vendor
# verdict: every check on the files patches 0005-0010 touch (MacTerminalView.swift,
# AppleTerminalView.swift, TerminalViewSearch.swift, FrameDriver.swift,
# Apple/Metal/MetalTerminalRenderer.swift, Apple/Metal/CoreTextGlyphRasterizer.swift).
#
# Re-vendor 2026-10-27 (upstream c3436be). MacDisplayLinkPacer.swift is gone upstream;
# patch 0010 now targets FrameDriver.swift instead.
# Patch 0013 (combining-mark): DROPPED — upstream cellOrdinal/anchorOrdinal fixes it.
# Patch 0010 (DisplayLink pacer): DROPPED as old; new 0010 is adaptive-pause in FrameDriver.

# --- MacTerminalView.swift (patches 0005 draw() open, 0006 search hook) ------
MTV="$VENDOR/Sources/SwiftTerm/Mac/MacTerminalView.swift"
if [[ ! -f "$MTV" ]]; then err "error: MacTerminalView.swift missing."; exit 1; fi
GOT_MTV="$(sha256_of "$MTV")"
WANT_MTV="$(pin_value patched_mac_terminal_view)"
WANT_MTV_UP="$(pin_value upstream_mac_terminal_view)"
if [[ "$GOT_MTV" == "$WANT_MTV_UP" ]]; then
  err "error: MacTerminalView.swift is UNPATCHED upstream."
  err "Patches 0005 (draw open) and 0006 (search hook) are required."
  exit 2
fi
if [[ "$GOT_MTV" != "$WANT_MTV" ]]; then
  err "error: MacTerminalView.swift hash mismatch."
  err "  expected (patched): $WANT_MTV"
  err "  found:              $GOT_MTV"
  err "  Hash covers patches 0005, 0006, and performKeyEquivalent open fix."
  exit 3
fi

# --- AppleTerminalView.swift (patches 0007-0010, 0012, compat shims) ---------
ATV="$VENDOR/Sources/SwiftTerm/Apple/AppleTerminalView.swift"
if [[ ! -f "$ATV" ]]; then err "error: AppleTerminalView.swift missing."; exit 1; fi
GOT_ATV="$(sha256_of "$ATV")"
WANT_ATV="$(pin_value patched_apple_terminal_view)"
WANT_ATV_UP="$(pin_value upstream_apple_terminal_view)"
if [[ "$GOT_ATV" == "$WANT_ATV_UP" ]]; then
  err "error: AppleTerminalView.swift is UNPATCHED upstream."
  exit 2
fi
if [[ "$GOT_ATV" != "$WANT_ATV" ]]; then
  err "error: AppleTerminalView.swift hash mismatch."
  err "  expected (patched): $WANT_ATV"
  err "  found:              $GOT_ATV"
  err "  Hash covers patches 0007 (colour emoji rasterizer backingScale/disableLigatures in"
  err "  FrameViewState+SnapshotRenderContext), 0008 (disableLigatures property + getAttributes),"
  err "  0009 (scrollbar thumb), 0010 (adaptiveIdlePauseEnabled + frameTimingObserver shims),"
  err "  0012 (createImage/createImageFromBitmap guards), and getTerminal() compat shim."
  exit 3
fi

# --- TerminalViewSearch.swift (patch 0006 findAllMatchPositions) ---------------
TVS="$VENDOR/Sources/SwiftTerm/TerminalViewSearch.swift"
if [[ ! -f "$TVS" ]]; then err "error: TerminalViewSearch.swift missing."; exit 1; fi
GOT_TVS="$(sha256_of "$TVS")"
if [[ "$GOT_TVS" != "$(pin_value patched_terminal_view_search)" ]]; then
  err "error: TerminalViewSearch.swift hash mismatch (patch 0006 findAllMatchPositions)."
  err "  Regenerate: shasum -a 256 $TVS"
  exit 3
fi

# --- FrameDriver.swift (patch 0010 adaptive idle-pause) ----------------------
FD="$VENDOR/Sources/SwiftTerm/Apple/FrameDriver.swift"
if [[ ! -f "$FD" ]]; then err "error: FrameDriver.swift missing."; exit 1; fi
GOT_FD="$(sha256_of "$FD")"
WANT_FD="$(pin_value patched_frame_driver)"
WANT_FD_UP="$(pin_value upstream_frame_driver)"
if [[ "$GOT_FD" == "$WANT_FD_UP" ]]; then
  err "error: FrameDriver.swift is UNPATCHED upstream."
  err "Patch 0010 (adaptive idle-pause) is not applied."
  exit 2
fi
if [[ "$GOT_FD" != "$WANT_FD" ]]; then
  err "error: FrameDriver.swift hash mismatch (patch 0010 adaptive idle-pause)."
  err "  expected: $WANT_FD"
  err "  found:    $GOT_FD"
  exit 3
fi

# --- CoreTextGlyphRasterizer.swift (patch 0007 colour emoji) -----------------
CTGR="$VENDOR/Sources/SwiftTerm/Apple/Metal/CoreTextGlyphRasterizer.swift"
if [[ ! -f "$CTGR" ]]; then err "error: CoreTextGlyphRasterizer.swift missing."; exit 1; fi
GOT_CTGR="$(sha256_of "$CTGR")"
WANT_CTGR="$(pin_value patched_core_text_glyph_rasterizer)"
WANT_CTGR_UP="$(pin_value upstream_core_text_glyph_rasterizer)"
if [[ "$GOT_CTGR" == "$WANT_CTGR_UP" ]]; then
  err "error: CoreTextGlyphRasterizer.swift is UNPATCHED upstream."
  err "Patch 0007 (colour emoji logical-size rasterizer) is not applied."
  exit 2
fi
if [[ "$GOT_CTGR" != "$WANT_CTGR" ]]; then
  err "error: CoreTextGlyphRasterizer.swift hash mismatch."
  err "  expected: $WANT_CTGR  found: $GOT_CTGR"
  exit 3
fi

# --- MetalTerminalRenderer.swift (patches 0007+0008) -------------------------
MTR="$VENDOR/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift"
if [[ ! -f "$MTR" ]]; then err "error: MetalTerminalRenderer.swift missing."; exit 1; fi
GOT_MTR="$(sha256_of "$MTR")"
WANT_MTR="$(pin_value patched_metal_terminal_renderer)"
WANT_MTR_UP="$(pin_value upstream_metal_terminal_renderer)"
if [[ "$GOT_MTR" == "$WANT_MTR_UP" ]]; then
  err "error: MetalTerminalRenderer.swift is UNPATCHED upstream."
  err "Patches 0007 (backingScale capture) and 0008 (ShaperKey.disableLigatures) not applied."
  exit 2
fi
if [[ "$GOT_MTR" != "$WANT_MTR" ]]; then
  err "error: MetalTerminalRenderer.swift hash mismatch (patches 0007+0008)."
  err "  expected: $WANT_MTR  found: $GOT_MTR"
  exit 3
fi
