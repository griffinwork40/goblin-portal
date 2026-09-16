#!/bin/bash
#
# Assemble a real .app bundle from the SwiftPM build product.
#
# Why a script instead of an .xcodeproj: the project stays entirely text —
# diffable, reviewable, and editable by tooling — instead of a binary blob that
# churns on every touch. The tradeoff is that we hand-write Info.plist, which is
# a dozen lines and rarely changes.
#
# Usage:
#   ./Scripts/make-app-bundle.sh [debug|release]
#
# Output: build/GoblinPortal.app
#
set -euo pipefail

CONFIG="${1:-debug}"
APP_NAME="GoblinPortal"
BUNDLE_ID="com.griffinlong.goblin-portal"
VERSION="1.0.0"

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

# Verify the vendored SwiftTerm before compiling anything. vendor/ is gitignored and
# app/Package.swift's path dependency is unpinned, so a re-vendored-but-unpatched tree
# would otherwise build GREEN against a different dependency than the tested one —
# see Scripts/verify-vendor.sh for why that case is silent and this one is not.
"$ROOT/Scripts/verify-vendor.sh"

# The SDK version embedded in the Mach-O LC_BUILD_VERSION load command is what
# macOS reads to decide whether to apply Liquid Glass and other modern visuals.
# SwiftPM sets both `minos` AND `sdk` to the deployment target (14.0), which puts
# the app in compatibility mode on macOS 26+ even though it was compiled against
# the current SDK. The fix: pass -platform_version to the linker with the real
# SDK version, keeping the deployment target (minos) at 14.0.
#
# Verified by otool -l: without this flag, sdk=14.0; with it, sdk=<actual>.
# Apple's Terminal.app shows minos=27.0 sdk=27.0; Goblin Portal needs minos=14.0 sdk=27.0
# because it still supports macOS 14 (Package.swift:11).
ACTUAL_SDK_VERSION="$(xcrun --show-sdk-version 2>/dev/null || echo "14.0")"
PLATFORM_VERSION_FLAGS="-Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker $ACTUAL_SDK_VERSION"

echo "==> swift build -c $CONFIG (sdk $ACTUAL_SDK_VERSION)"
swift build -c "$CONFIG" $PLATFORM_VERSION_FLAGS

BIN_DIR="$(swift build -c "$CONFIG" $PLATFORM_VERSION_FLAGS --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"
if [[ ! -x "$BIN" ]]; then
  echo "error: expected executable at $BIN" >&2
  exit 1
fi

APP="$ROOT/build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

# CLI binary (`goblin-portal`). Installed into the app bundle so it travels with the app
# and is versioned together with it. The recommended install path for users is
# /usr/local/bin/goblin-portal, added as a symlink to the bundle's copy so updates to
# GoblinPortal.app are picked up automatically without re-running any installer:
#
#   sudo ln -sf /Applications/GoblinPortal.app/Contents/MacOS/goblin-portal /usr/local/bin/goblin-portal
#
# We install the binary at Contents/MacOS/goblin-portal (lowercase) alongside GoblinPortal so
# codesign and notarisation treat it as part of the same bundle.
CLI_BIN="$BIN_DIR/GoblinPortalCLI"
if [[ -x "$CLI_BIN" ]]; then
  cp "$CLI_BIN" "$APP/Contents/MacOS/goblin-portal"
  echo "==> installed CLI binary: $APP/Contents/MacOS/goblin-portal"
else
  echo "==> warning: GoblinPortalCLI binary not found at $CLI_BIN — 'umber' CLI will not be bundled" >&2
fi

# Any resource bundles SwiftPM produced for dependencies must travel with the
# app, or code that looks them up at runtime finds nothing once the binary is
# moved out of .build.
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
  cp -R "$bundle" "$APP/Contents/Resources/"
done
shopt -u nullglob

# Shell-integration script. Bundled in Resources/ so TerminalPane.start() can
# locate it via Bundle.main.path(forResource:ofType:) and set GOBLIN_PORTAL_INTEGRATION.
SHELL_INT_SRC="$ROOT/Resources/shell-integration.zsh"
if [[ -f "$SHELL_INT_SRC" ]]; then
  cp "$SHELL_INT_SRC" "$APP/Contents/Resources/shell-integration.zsh"
else
  echo "==> warning: $SHELL_INT_SRC missing; shell-integration will not be available" >&2
fi

# App icon. Resources/GoblinPortal.icns is committed so a build needs no Python or
# Pillow; regenerate it with Scripts/make-icon.py --icns when the design changes.
ICON_SRC="$ROOT/Resources/$APP_NAME.icns"
if [[ -f "$ICON_SRC" ]]; then
  cp "$ICON_SRC" "$APP/Contents/Resources/$APP_NAME.icns"
  ICON_PLIST_ENTRY="	<key>CFBundleIconFile</key>
	<string>$APP_NAME</string>
"
else
  echo "==> warning: $ICON_SRC missing; bundling without an icon" >&2
  ICON_PLIST_ENTRY=""
fi

# The NS*UsageDescription keys are not paperwork — on macOS a TCC-gated request from
# a process with no matching key is DENIED, and for the folder classes it is denied
# silently, with no prompt and no entry in Privacy & Security for the user to grant
# afterwards. A terminal inherits every one of these requests from whatever the user
# runs inside it, so `cd ~/Documents && ls` in a shell hosted by a bundle without
# NSDocumentsFolderUsageDescription simply returns "Operation not permitted" and
# there is nowhere to go to fix it. (Microphone and AppleEvents are worse still: the
# request is met with SIGABRT rather than an error — that is what #23 fixed.)
# SDK metadata for provenance. The FUNCTIONAL mechanism for Liquid Glass is the
# Mach-O LC_BUILD_VERSION sdk field (set by -platform_version above, verified by
# otool -l). These Info.plist DT* keys are what Xcode writes for tooling and are
# COSMETIC — macOS does not read them for compatibility mode. They are still
# useful: crash reporters, `mdls`, and Instruments read them for context.
DT_SDK_NAME="macosx$(xcrun --show-sdk-version 2>/dev/null || echo "14.0")"
DT_SDK_BUILD="$(xcrun --show-sdk-build-version 2>/dev/null || echo "unknown")"
DT_PLATFORM_NAME="macosx"
DT_PLATFORM_VERSION="$(xcrun --show-sdk-version 2>/dev/null || echo "14.0")"
DT_XCODE="$(xcodebuild -version 2>/dev/null | awk '/^Xcode/ {gsub(/\./,"",$2); print $2}' || echo "1500")"
DT_XCODE_BUILD="$(xcodebuild -version 2>/dev/null | awk '/^Build/ {print $3}' || echo "unknown")"
DT_MACHINE_BUILD="$(sw_vers -buildVersion 2>/dev/null || echo "unknown")"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>$APP_NAME</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundleDisplayName</key>
	<string>$APP_NAME</string>
${ICON_PLIST_ENTRY}	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
	<key>NSMicrophoneUsageDescription</key>
	<string>A program running within Goblin Portal would like to use your microphone.</string>
	<key>NSAppleEventsUsageDescription</key>
	<string>A program running within Goblin Portal would like to control another application.</string>
	<key>NSDesktopFolderUsageDescription</key>
	<string>A program running within Goblin Portal would like to access files on your Desktop.</string>
	<key>NSDocumentsFolderUsageDescription</key>
	<string>A program running within Goblin Portal would like to access files in your Documents folder.</string>
	<key>NSDownloadsFolderUsageDescription</key>
	<string>A program running within Goblin Portal would like to access files in your Downloads folder.</string>
	<key>NSRemovableVolumesUsageDescription</key>
	<string>A program running within Goblin Portal would like to access files on a removable volume.</string>
	<key>NSNetworkVolumesUsageDescription</key>
	<string>A program running within Goblin Portal would like to access files on a network volume.</string>
	<key>NSUserNotificationsUsageDescription</key>
	<string>Goblin Portal notifies you when a long-running command finishes in a background tab.</string>
	<key>NSHumanReadableCopyright</key>
	<string>Copyright © 2026 Griffin Long. MIT licensed. Includes SwiftTerm and Ghostty; see THIRD-PARTY-LICENSES.md.</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSSupportsAutomaticTermination</key>
	<false/>
	<key>NSSupportsSuddenTermination</key>
	<false/>
	<key>DTSDKName</key>
	<string>$DT_SDK_NAME</string>
	<key>DTSDKBuild</key>
	<string>$DT_SDK_BUILD</string>
	<key>DTPlatformName</key>
	<string>$DT_PLATFORM_NAME</string>
	<key>DTPlatformVersion</key>
	<string>$DT_PLATFORM_VERSION</string>
	<key>DTXcode</key>
	<string>$DT_XCODE</string>
	<key>DTXcodeBuild</key>
	<string>$DT_XCODE_BUILD</string>
	<key>BuildMachineOSBuild</key>
	<string>$DT_MACHINE_BUILD</string>
</dict>
</plist>
PLIST

# Signing. The default "-" is an ad-hoc signature: enough for the app to launch on
# the machine that built it, and nothing more — a build downloaded from anywhere
# arrives quarantined and Gatekeeper refuses it until the user strips the attribute
# (see README.md). Set SIGN_IDENTITY to a Developer ID to produce a distribution build:
#
#   SIGN_IDENTITY="Developer ID Application: Griffin Long (TEAMID)" ./Scripts/make-app-bundle.sh release
#
# When a real identity is supplied the script enables the hardened runtime, signs every
# embedded bundle inside-out (Apple requires innermost first), and — when notarisation
# credentials are also present — submits, waits, and staples in one pass. The ad-hoc
# path is unchanged: no hardened runtime, no notarisation, works on the local machine.
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
ENTITLEMENTS="$ROOT/Resources/GoblinPortal.entitlements"

if [[ "$SIGN_IDENTITY" != "-" ]]; then
  # --- Distribution signing: hardened runtime + entitlements ---
  if [[ ! -f "$ENTITLEMENTS" ]]; then
    echo "error: $ENTITLEMENTS not found — cannot sign with hardened runtime" >&2
    exit 1
  fi

  # Sign embedded bundles first (inside-out). Each must be signed individually before
  # the outer app signature seals the tree — signing the outer app alone with --deep
  # works on some macOS versions but notarytool rejects it on others.
  #
  # SwiftPM resource bundles (e.g. SwiftTerm_SwiftTerm.bundle containing the Metal
  # shader) have no executable and no proper bundle structure — codesign rejects them
  # with "bundle format unrecognized". These are data-only bundles sealed by the outer
  # app signature; signing them individually is neither possible nor necessary.
  echo "==> signing embedded bundles"
  shopt -s nullglob
  for bundle in "$APP/Contents/Resources/"*.bundle; do
    if [[ -f "$bundle/Contents/Info.plist" ]] && \
       plutil -extract CFBundleExecutable raw "$bundle/Contents/Info.plist" >/dev/null 2>&1; then
      codesign --force --sign "$SIGN_IDENTITY" \
        --options runtime \
        --entitlements "$ENTITLEMENTS" \
        --timestamp \
        "$bundle"
      echo "    signed $(basename "$bundle")"
    else
      echo "    skipped $(basename "$bundle") (resource-only, no executable)"
    fi
  done
  shopt -u nullglob

  echo "==> signing $APP_NAME.app (hardened runtime)"
  codesign --force --sign "$SIGN_IDENTITY" \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --timestamp \
    "$APP"

  # Verify the signature is valid and the hardened runtime flag is set.
  codesign -v --verbose=2 "$APP" 2>&1
  echo "==> signed with: $SIGN_IDENTITY"

  # --- Notarisation (optional, requires credentials) ---
  # Apple accepts three credential forms for notarytool:
  #   1. App Store Connect API key (recommended for CI):
  #        NOTARIZE_KEY_ID, NOTARIZE_ISSUER, NOTARIZE_KEY_PATH
  #   2. Apple ID + app-specific password:
  #        NOTARIZE_APPLE_ID, NOTARIZE_PASSWORD, NOTARIZE_TEAM_ID
  #   3. Keychain profile (recommended for local use):
  #        NOTARIZE_PROFILE (set up once with `xcrun notarytool store-credentials`)
  #
  # When none are set the build still produces a signed, hardened-runtime app — it just
  # triggers Gatekeeper's "unnotarised" dialog on first launch.
  NOTARIZE=false
  NOTARY_ARGS=()

  if [[ -n "${NOTARIZE_PROFILE:-}" ]]; then
    NOTARIZE=true
    NOTARY_ARGS=(--keychain-profile "$NOTARIZE_PROFILE")
  elif [[ -n "${NOTARIZE_KEY_ID:-}" && -n "${NOTARIZE_ISSUER:-}" && -n "${NOTARIZE_KEY_PATH:-}" ]]; then
    NOTARIZE=true
    NOTARY_ARGS=(--key "$NOTARIZE_KEY_PATH" --key-id "$NOTARIZE_KEY_ID" --issuer "$NOTARIZE_ISSUER")
  elif [[ -n "${NOTARIZE_APPLE_ID:-}" && -n "${NOTARIZE_PASSWORD:-}" && -n "${NOTARIZE_TEAM_ID:-}" ]]; then
    NOTARIZE=true
    NOTARY_ARGS=(--apple-id "$NOTARIZE_APPLE_ID" --password "$NOTARIZE_PASSWORD" --team-id "$NOTARIZE_TEAM_ID")
  fi

  if [[ "$NOTARIZE" == "true" ]]; then
    echo "==> notarising (this takes 1–5 minutes)"
    ZIP_TMP="$(mktemp -d)/GoblinPortal-notarize.zip"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP_TMP"

    xcrun notarytool submit "$ZIP_TMP" "${NOTARY_ARGS[@]}" --wait

    rm -f "$ZIP_TMP"

    echo "==> stapling ticket"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    echo "==> notarisation complete"
  else
    echo "==> skipping notarisation (no credentials — set NOTARIZE_PROFILE, or see script comments)"
  fi

else
  # --- Ad-hoc signing: local use only ---
  if codesign --force --sign "-" "$APP" >/dev/null 2>&1; then
    echo "==> ad-hoc signed (local use only; a downloaded copy needs xattr -dr com.apple.quarantine)"
  else
    echo "==> warning: codesign failed; app may still launch locally"
  fi
fi

echo "==> built $APP"
echo "    open $APP"
