#!/bin/bash
#
# Assert that the Info.plist Goblin Portal ships carries every privacy usage-description
# key a terminal needs, each with a non-empty string, and that the plist is well-formed.
#
# WHAT IS UNDER TEST. The Info.plist heredoc in Scripts/make-app-bundle.sh — the only
# place the app's Info.plist is written (there is no .xcodeproj and no template file).
# The heredoc is extracted from the SHIPPED script, its shell variables are replaced with
# placeholders, and the result is linted and queried with plutil. No build is needed.
# With --bundle PATH it checks a BUILT app's Contents/Info.plist instead, which is how
# a release zip can be verified with the same list.
#
# WHY IT EXISTS. A missing NS*UsageDescription key is a silent failure: macOS denies the
# TCC-gated request with no prompt and nowhere in Privacy & Security to grant it. A
# terminal inherits every such request from whatever runs inside it. v1.12.0 and earlier
# lacked NSLocalNetworkUsageDescription, so Local Network privacy denied LAN connections
# from node and python (EHOSTUNREACH, "No route to host") while Apple-exempt ssh/nc/ping
# worked — it looked like a routing fault, not a missing plist key.
#
# Falsification is built in (case F): a copy of the heredoc with the
# NSLocalNetworkUsageDescription key deleted must FAIL the same assertions; if it passes,
# the gate is blind and exits 1.
#
# Usage:
#   ./Scripts/check-info-plist.sh                       # check make-app-bundle.sh's heredoc
#   ./Scripts/check-info-plist.sh --bundle "build/Goblin Portal.app"
#
# Exit codes: 0 all keys present, 1 a key is missing/empty or the gate is blind,
#             2 environmental (no plutil, script or bundle missing, heredoc not found).

set -euo pipefail
cd "$(dirname "$0")/.."

REQUIRED_KEYS=(
  NSLocalNetworkUsageDescription
  NSMicrophoneUsageDescription
  NSAppleEventsUsageDescription
  NSDesktopFolderUsageDescription
  NSDocumentsFolderUsageDescription
  NSDownloadsFolderUsageDescription
  NSRemovableVolumesUsageDescription
  NSNetworkVolumesUsageDescription
  NSUserNotificationsUsageDescription
)

command -v plutil >/dev/null 2>&1 || { echo "check-info-plist: environment: no plutil" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# check_plist FILE -> prints one line per failure, returns the failure count (0 = clean).
check_plist() {
  local plist="$1" fails=0 key val
  if ! plutil -lint -s "$plist" >/dev/null 2>&1; then
    echo "  FAIL plist is not well-formed: $(plutil -lint "$plist" 2>&1 | tail -1)"
    return 1
  fi
  for key in "${REQUIRED_KEYS[@]}"; do
    if ! val="$(plutil -extract "$key" raw -o - "$plist" 2>/dev/null)"; then
      echo "  FAIL missing $key"; fails=$((fails + 1))
    elif [ -z "${val// /}" ]; then
      echo "  FAIL empty $key"; fails=$((fails + 1))
    else
      echo "  ok   $key"
    fi
  done
  return "$fails"
}

if [ "${1:-}" = "--bundle" ]; then
  PLIST="${2:-}/Contents/Info.plist"
  [ -f "$PLIST" ] || { echo "check-info-plist: environment: no $PLIST" >&2; exit 2; }
  echo "==> built bundle: $PLIST"
  if check_plist "$PLIST"; then echo "check-info-plist: OK"; exit 0; fi
  echo "check-info-plist: FAILED"; exit 1
fi

SCRIPT="Scripts/make-app-bundle.sh"
[ -f "$SCRIPT" ] || { echo "check-info-plist: environment: $SCRIPT missing" >&2; exit 2; }

# The heredoc body: everything between the `<<PLIST` line and the closing `PLIST`.
# ${ICON_PLIST_ENTRY} expands to whole lines (or nothing), so it is dropped; every other
# $VAR / ${VAR} becomes a placeholder string so the XML stays valid.
awk '/<<PLIST$/ {on=1; next} on && /^PLIST$/ {exit} on {print}' "$SCRIPT" \
  | sed -e 's/\${ICON_PLIST_ENTRY}//' -e 's/\${\{0,1\}[A-Z_][A-Z0-9_]*}\{0,1\}/placeholder/g' \
  > "$TMP/Info.plist"
grep -q '<plist' "$TMP/Info.plist" \
  || { echo "check-info-plist: environment: Info.plist heredoc not found in $SCRIPT" >&2; exit 2; }

echo "==> $SCRIPT Info.plist heredoc"
status=0
check_plist "$TMP/Info.plist" || status=1

# Case F: falsification. Delete the NSLocalNetworkUsageDescription key and its string;
# the same check must now fail, or it was never measuring the heredoc.
awk '/<key>NSLocalNetworkUsageDescription<\/key>/ {skip=2} skip > 0 {skip--; next} {print}' \
  "$TMP/Info.plist" > "$TMP/Mutant.plist"
echo "==> falsification: heredoc without NSLocalNetworkUsageDescription must fail"
if check_plist "$TMP/Mutant.plist" >/dev/null; then
  echo "  FAIL gate is BLIND: the mutant without the key passed"; status=1
else
  echo "  ok   mutant rejected"
fi

if [ "$status" -eq 0 ]; then echo "check-info-plist: OK"; else echo "check-info-plist: FAILED"; fi
exit "$status"
