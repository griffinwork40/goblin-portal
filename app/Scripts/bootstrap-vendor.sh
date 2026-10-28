#!/bin/bash
#
# Materialise vendor/SwiftTerm from nothing: clone the pinned upstream, apply the
# local patch series, and hand off to verify-vendor.sh for the verdict.
#
# Why this script exists: vendor/ is gitignored (.gitignore:20) but
# app/Package.swift declares `.package(path: "../vendor/SwiftTerm")`, so a fresh
# `git clone` of this repo CANNOT BUILD AT ALL — SwiftPM fails on a missing local
# path dependency before compiling a line. Until this script existed, the only
# recovery was a six-step recipe buried in app/README.md that grew a step every
# time a patch landed. That is a bad first impression and a real barrier to
# anyone who is not the author.
#
# Why it is separate from verify-vendor.sh: that script is a pure, offline,
# read-only assertion — it is called on every `make-app-bundle.sh` run and must
# stay cheap and side-effect-free. This one reaches the network and writes to the
# tree. Folding them together would mean a routine build could silently re-clone
# a dependency, which is exactly the kind of surprise the pin exists to prevent.
# So: verify-vendor.sh decides, bootstrap-vendor.sh acts, and the acting one ends
# by asking the deciding one whether it succeeded.
#
# Usage:
#   ./Scripts/bootstrap-vendor.sh            # clone + patch + verify
#   ./Scripts/bootstrap-vendor.sh --force    # discard an existing vendor/ first
#
# Exit codes mirror verify-vendor.sh, because this script's last act is to
# delegate to it and propagate:
#   0  vendor/SwiftTerm is present and matches the pin (freshly built, or already
#      good and left alone)
#   1  prerequisites missing, clone failed, a patch did not apply, or the tree is
#      in a state this script refuses to repair in place
#   2  present but UNPATCHED   (propagated from verify-vendor.sh)
#   3  present but an unknown revision (propagated from verify-vendor.sh)
#
set -euo pipefail

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

# Scripts/ lives in app/; the vendored copy and its patches are at the repo root.
# Same two-line preamble as verify-vendor.sh, deliberately — these two scripts
# must agree on where everything is or they will disagree about what they found.
cd "$(dirname "$0")/.."
APP_ROOT="$(pwd)"
REPO_ROOT="$(cd .. && pwd)"

VENDOR="$REPO_ROOT/vendor/SwiftTerm"
PIN="$REPO_ROOT/patches/swiftterm/SwiftTerm.pin"
PATCH_DIR="$REPO_ROOT/patches/swiftterm"
VERIFY="$APP_ROOT/Scripts/verify-vendor.sh"

err() { echo "$@" >&2; }

# `key = value` out of the pin. Copied verbatim from verify-vendor.sh:74-76 so the
# two scripts cannot drift into parsing the same file differently.
pin_value() {
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$PIN" | head -1 | tr -d '[:space:]'
}

# --- prerequisites -------------------------------------------------------------
# The patch series is ordered and every entry is required. Vendored against upstream
# c3436be (post-IO-rewrite, post-FrameDriver). Dropped from v1.15.0 series:
# 0002 (isWrapped buffer-absolute), 0006/0007 (selection-clear gates), 0010
# (DisplayLink pacer), 0011 (empty-glyph cache), 0013 (combining-mark fix), 0020
# (sixel bounds) — all incorporated by the upstream IO rewrite at c3436be.
#
# 0001 makes a CLT-only build possible (Shaders.metal as .copy, not excluded);
# 0002 fixes the alt-buffer narrowing trim so it runs for every buffer (#3 in v1.15.0);
# 0003 gates the resize post-condition fatalError behind #if DEBUG (#4 in v1.15.0);
# 0004 adds DCS Ptmux passthrough so tmux can forward SGR sequences (#5 in v1.15.0);
# 0005 makes draw(_:) `open` so GoblinPortalTerminalView can override it (#8);
# 0006 adds searchStateDidChange hook + findAllMatchPositions for all-match highlights (#9);
# 0007 rasterizes colour emoji at logical size under a scaled CTM (N4, Metal path) (#12);
# 0008 adds `open var disableLigatures` to TerminalView, backing Bool to MacTerminalView,
#      and kCTLigatureAttributeName injection to Core Text + Metal ShaperCache (#14);
# 0009 replaces the 0.01 scrollbar thumb floor with 1/rows (#15);
# 0010 adds adaptive idle-pause to FrameDriver: slow producers pause after 1 idle tick
#      instead of 8 (#16, ported from MacDisplayLinkPacer to FrameDriver);
# 0011 adds Terminal.xtVersion host-app override to cmdXTVERSION, and mode 2027
#      (modeAlwaysReset) to cmdDecRqm; alternateScrollMode/1007/scrollWheel already
#      upstream (#17 partial);
# 0012 bounds the OSC 1337 encoded payload (32 MiB) and adds ImageIO type/dimension
#      header checks to createImage and createImageFromBitmap; OSC cap already upstream (#18 partial);
# 0013 adds OSC 1337 MultipartFile/FilePart/FileEnd (modern imgcat default) (#19).
# A tree missing any one of them is not the tree this project is tested against.
PATCHES=(
  "0001-ship-metal-shader-as-copy-resource.patch"
  "0002-trim-lines-on-narrowing-for-all-buffers.patch"
  "0003-gate-resize-post-condition-behind-debug.patch"
  "0004-add-dcs-ptmux-passthrough.patch"
  "0005-make-draw-open-for-subclass-override.patch"
  "0006-expose-search-state-changed-hook.patch"
  "0007-rasterize-color-glyphs-at-logical-size.patch"
  "0008-disable-ligatures-both-renderers.patch"
  "0009-proportional-scrollbar-thumb.patch"
  "0010-pause-sooner-for-slow-producers.patch"
  "0011-xtversion-host-override-mode2027.patch"
  "0012-bound-inline-image-payloads.patch"
  "0013-osc1337-multipart-file.patch"
)

if [[ ! -f "$PIN" ]]; then
  err "error: missing patches/swiftterm/SwiftTerm.pin"
  err "       The vendor pin is part of the build contract; do not delete it."
  exit 1
fi
for p in "${PATCHES[@]}"; do
  if [[ ! -f "$PATCH_DIR/$p" ]]; then
    err "error: missing patches/swiftterm/$p"
    err "       Every patch in the series is required; see SwiftTerm.pin for why."
    exit 1
  fi
done
for tool in git patch shasum; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    err "error: '$tool' not found on PATH. Install the Xcode Command Line Tools:"
    err "       xcode-select --install"
    exit 1
  fi
done
if [[ ! -x "$VERIFY" ]]; then
  err "error: Scripts/verify-vendor.sh is missing or not executable."
  err "       bootstrap-vendor.sh deliberately owns no verdict of its own."
  exit 1
fi

UPSTREAM_REPO="$(pin_value upstream_repo)"
UPSTREAM_TAG="$(pin_value upstream_tag)"
UPSTREAM_COMMIT="$(pin_value upstream_commit)"

# --- already present? ----------------------------------------------------------
# Re-entry is the case worth getting right: someone runs this twice, or runs it in
# a tree that already builds. Do NOT attempt an in-place repair. SwiftTerm.pin:76-78
# spells out why — a half-patched tree matches neither the patched nor the upstream
# hash, and "half-patched is not a state this project supports". So: a good tree is
# left strictly alone, and anything else is reported with the one-line fix.
if [[ -d "$VENDOR" ]]; then
  if [[ "$FORCE" == "1" ]]; then
    echo "==> --force: removing existing vendor/SwiftTerm"
    rm -rf "$VENDOR"
  else
    set +e
    "$VERIFY" --quiet
    rc=$?
    set -e
    if [[ "$rc" == "0" ]]; then
      echo "==> vendor/SwiftTerm already present and matches the pin — nothing to do."
      exit 0
    fi
    err "error: vendor/SwiftTerm exists but does not match the pin (verify-vendor.sh exit $rc)."
    err ""
    err "This script will not repair a tree in place — a partly-patched checkout is"
    err "indistinguishable from a differently-patched one, and guessing would produce a"
    err "build that is green against a dependency nobody tested. Start clean:"
    err ""
    err "  ./Scripts/bootstrap-vendor.sh --force"
    err ""
    err "Run ./Scripts/verify-vendor.sh (without --quiet) for the specific mismatch."
    exit "$rc"
  fi
fi

# --- clone ---------------------------------------------------------------------
# Assembled in a temp directory and moved into place only once it is complete and
# patched. An interrupted clone therefore never leaves a partial vendor/SwiftTerm
# behind for the next run to puzzle over — the failure mode the re-entry branch
# above would otherwise have to guess about.
mkdir -p "$REPO_ROOT/vendor"
STAGE="$(mktemp -d "$REPO_ROOT/vendor/.bootstrap.XXXXXX")"
cleanup() { [[ -n "${STAGE:-}" && -d "$STAGE" ]] && rm -rf "$STAGE"; }
trap cleanup EXIT

echo "==> cloning $UPSTREAM_REPO @ $UPSTREAM_COMMIT"
# When upstream_tag = MAIN (no released tag at this commit), clone the full repo
# and check out the pinned commit. When a tag is present, use a shallow clone.
if [[ "$UPSTREAM_TAG" == "MAIN" ]]; then
  # Full clone needed to reach an arbitrary commit; --filter=blob:none keeps it lean.
  if ! git -c advice.detachedHead=false clone --quiet --filter=blob:none \
       "$UPSTREAM_REPO" "$STAGE/SwiftTerm"; then
    err "error: clone failed. This step needs network access."
    err "       repo: $UPSTREAM_REPO"
    exit 1
  fi
  if ! git -C "$STAGE/SwiftTerm" -c advice.detachedHead=false checkout --quiet "$UPSTREAM_COMMIT"; then
    err "error: could not checkout pinned commit $UPSTREAM_COMMIT."
    err "       The commit may not exist on the default branch, or the repo is shallow."
    exit 1
  fi
else
  # advice.detachedHead is off because cloning a TAG always detaches, so git's
  # fourteen-line lecture fires on every single run and buries the important line.
  if ! git -c advice.detachedHead=false clone --quiet --depth 1 \
       --branch "$UPSTREAM_TAG" "$UPSTREAM_REPO" "$STAGE/SwiftTerm"; then
    err "error: clone failed. This step needs network access."
    err "       repo: $UPSTREAM_REPO"
    err "       tag:  $UPSTREAM_TAG"
    exit 1
  fi
fi

# A tag is a movable label; the pin records a commit for a reason. verify-vendor.sh
# only ever echoes upstream_commit cosmetically (:205), so without this check a
# retagged upstream would sail through as long as the two file hashes still matched
# — and those cover two files out of several hundred.
GOT_COMMIT="$(git -C "$STAGE/SwiftTerm" rev-parse HEAD)"
if [[ "$GOT_COMMIT" != "$UPSTREAM_COMMIT" ]]; then
  err "error: $UPSTREAM_TAG resolved to a commit the pin does not name."
  err "       expected: $UPSTREAM_COMMIT"
  err "       got:      $GOT_COMMIT"
  err ""
  err "The upstream tag has moved, or the pin is stale. Do not proceed by hand —"
  err "re-derive the hashes in SwiftTerm.pin against the new revision first."
  exit 1
fi

# The clone's .git is a depth-1 stub carrying no history worth keeping, and leaving
# it makes `git status` inside vendor/ report the applied patches as if they
# were someone's uncommitted edits. Removing it also matches the shape a maintainer's
# machine already has, so every check script sees one tree shape rather than two.
rm -rf "$STAGE/SwiftTerm/.git"

# --- patch ---------------------------------------------------------------------
# --batch is load-bearing: without it `patch` prompts on any ambiguity and a CI job
# hangs forever instead of failing. --forward makes an already-applied patch an
# error rather than a silent reversal.
chmod -R u+w "$STAGE/SwiftTerm"
for p in "${PATCHES[@]}"; do
  echo "==> applying ${p%%-*} ${p#*-}"
  if ! patch -p1 --batch --forward -d "$STAGE/SwiftTerm" < "$PATCH_DIR/$p"; then
    err ""
    err "error: patch $p did not apply cleanly."
    err "       The upstream tree at $UPSTREAM_TAG is not what this patch was written"
    err "       against. Nothing was installed; vendor/SwiftTerm is untouched."
    exit 1
  fi
done

# `patch` can exit 0 having written a .rej for a partly-applied hunk. That is
# exactly the half-patched state the pin refuses to support, so treat it as fatal.
if find "$STAGE/SwiftTerm" -name '*.rej' -print -quit | grep -q .; then
  err "error: patch left .rej files — the series applied only partially."
  find "$STAGE/SwiftTerm" -name '*.rej' | sed "s|$STAGE/SwiftTerm|  vendor/SwiftTerm|"
  exit 1
fi

# --- install + verdict ---------------------------------------------------------
mv "$STAGE/SwiftTerm" "$VENDOR"
echo "==> installed vendor/SwiftTerm"

# The verdict is not this script's to give. If the hashes disagree with the pin,
# the exit code says so and the caller learns it from the same source a routine
# build would have.
exec "$VERIFY"
