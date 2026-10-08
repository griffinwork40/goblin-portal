#!/bin/bash
#
# cut-release.sh -- cut a Goblin Portal release with one command, from the main checkout.
#
# Why a script: the recipe in .github/workflows/release.yml's header (bump VERSION in
# make-app-bundle.sh, commit, tag, push the tag) was improvised by hand for the first 15
# releases (v0.1.0 through v1.8.0). Each step is easy; the failure modes are in the gaps
# between them: tagging a commit main's CI never saw, a tag that disagrees with VERSION
# (release.yml refuses it, but only after the push), and assets nobody re-verified after
# publish. v1.5.0 and v1.6.0 shipped a .dmg.sha256 that failed `shasum -c` and it was
# caught only after publishing (release.yml, the comment under "Package DMG"). So this
# script refuses before it writes, and re-verifies the published assets after.
#
# Usage (from anywhere inside the main checkout):
#   app/Scripts/cut-release.sh X.Y.Z --dry-run   # preflight + print the plan, change nothing
#   app/Scripts/cut-release.sh X.Y.Z             # do it
#
# Preflight (cut-release-preflight.sh, sourced): on main, no tracked changes, HEAD ==
# origin/main after a fetch, X.Y.Z strict semver and numerically > current VERSION, tag
# absent locally/on origin, no GitHub release vX.Y.Z, latest checks.yml run on main is
# HEAD's and green. Then: bump the one VERSION= line, commit, tag, push main, push tag,
# watch release.yml, download the four assets, `shasum -c` both sidecars, print the URL.
#
# Exit codes (the check-*.sh contract): 0 = released (or dry run passed preflight),
# 1 = refused or failed, 2 = environmental (no git/gh, network, auth). Any failure after
# a push prints exactly what state was left and how to finish, because a half-done
# release must be legible to whoever (or whatever) runs this next. See RELEASING.md.
#
# Runs under macOS's stock /bin/bash 3.2: no associative arrays, no ${var,,}, no mapfile.

set -euo pipefail

REPO="griffinwork40/goblin-portal"
BUNDLE_REL="app/Scripts/make-app-bundle.sh"

say()      { printf '%s\n' "$*"; }
refuse()   { printf 'cut-release: refused: %s\n' "$*" >&2; exit 1; }
env_fail() { printf 'cut-release: environment: %s\n' "$*" >&2; exit 2; }

# STATE names what has already happened, so an unexpected error after a write still
# reports it (the EXIT trap) instead of leaving the operator to reconstruct it from git.
STATE=""
REPORTED=0
TMP=""
fail() {
  REPORTED=1
  printf 'cut-release: FAILED: %s\n' "$1" >&2
  [ -z "$STATE" ] || printf 'cut-release: state left: %s\n' "$STATE" >&2
  [ -z "${2:-}" ] || printf 'cut-release: next: %s\n' "$2" >&2
  exit 1
}
on_exit() {
  rc=$?
  [ -z "$TMP" ] || rm -rf "$TMP"
  if [ "$rc" -ne 0 ] && [ "$REPORTED" -eq 0 ] && [ -n "$STATE" ]; then
    printf 'cut-release: unexpected error (exit %s); state left: %s\n' "$rc" "$STATE" >&2
  fi
}
trap on_exit EXIT

# --- arguments: validated before touching anything ---------------------------------
NEW=""; DRY=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '3,28p' "$0"; exit 0 ;;
    -*) refuse "unknown flag $arg (usage: cut-release.sh X.Y.Z [--dry-run])" ;;
    *) [ -z "$NEW" ] || refuse "more than one version given"; NEW="$arg" ;;
  esac
done
[ -n "$NEW" ] || refuse "usage: cut-release.sh X.Y.Z [--dry-run]"

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=cut-release-preflight.sh
. "$HERE/cut-release-preflight.sh"
is_semver "$NEW" || refuse "'$NEW' is not strict semver X.Y.Z (no leading v, no suffix)"
TAG="v$NEW"
CUR=""

command -v git >/dev/null 2>&1 || env_fail "git not found on PATH"
cd "$(git -C "$HERE" rev-parse --show-toplevel)" || env_fail "not inside a git checkout"

preflight

# A tag pushed anywhere but GitHub never triggers release.yml. Refused for real runs;
# a dry run only warns, so it can be rehearsed in a throwaway clone.
ORIGIN_URL="$(git remote get-url origin)"
case "$ORIGIN_URL" in
  *[/@]github.com[:/]"$REPO"|*[/@]github.com[:/]"$REPO".git) ORIGIN_OK=1 ;;
  *) ORIGIN_OK=0 ;;
esac

if [ "$DRY" -eq 1 ]; then
  [ "$ORIGIN_OK" -eq 1 ] || say "warning: origin is $ORIGIN_URL, not $REPO; a real run would refuse"
  say ""
  say "dry run: preflight passed; a real run would:"
  say "  1. rewrite $BUNDLE_REL: VERSION=\"$CUR\" -> VERSION=\"$NEW\" (assert one line changed)"
  say "  2. git commit -m 'chore(app): bump version to $NEW' (as AFK Agent <agent@agentafk.com>)"
  say "  3. git tag $TAG on that commit"
  say "  4. git push origin main, then git push origin $TAG"
  say "  5. find the release.yml run for $TAG and gh run watch --exit-status"
  say "  6. download GoblinPortal-$TAG.{zip,dmg} + .sha256 and shasum -a 256 -c both"
  say "  7. print the release URL"
  exit 0
fi
[ "$ORIGIN_OK" -eq 1 ] || refuse "origin is $ORIGIN_URL, not github.com/$REPO"

# --- 1. bump exactly one line --------------------------------------------------------
# awk + cat-into rather than `sed -i`, whose flag syntax differs between BSD and GNU;
# writing through the existing file keeps its executable bit.
TMP="$(mktemp -d)"
awk -v v="$NEW" '/^VERSION=/ { print "VERSION=\"" v "\""; next } { print }' \
  "$BUNDLE_REL" > "$TMP/bundle.sh"
cat "$TMP/bundle.sh" > "$BUNDLE_REL"
STATE="$BUNDLE_REL edited locally, nothing committed (undo: git checkout -- $BUNDLE_REL)"
numstat="$(git diff --numstat)"
[ "$numstat" = "$(printf '1\t1\t%s' "$BUNDLE_REL")" ] \
  || fail "version bump changed more than one line: $numstat" "git checkout -- $BUNDLE_REL"
grep -qx "VERSION=\"$NEW\"" "$BUNDLE_REL" || fail "VERSION line did not take" "git checkout -- $BUNDLE_REL"

# --- 2-3. commit and tag ----------------------------------------------------------------
# Identity pinned per-command, not read from git config, so the bump commit has the same
# author whoever runs this; the hand-cut bump commits (e.g. 96f5fd66 for 1.8.0) used it.
git -c user.name='AFK Agent' -c user.email='agent@agentafk.com' \
  commit -q -m "chore(app): bump version to $NEW" -- "$BUNDLE_REL"
git tag "$TAG"
SHA="$(git rev-parse HEAD)"
STATE="local commit $(short "$SHA") and local tag $TAG; NOTHING pushed (undo: git tag -d $TAG && git reset --hard origin/main)"
say "ok: committed $(short "$SHA") and tagged $TAG"

# --- 4. push main, then the tag ---------------------------------------------------------
# Main first: a tag pushed ahead of its commit's branch would point release.yml at a
# commit main does not contain.
git push -q origin main || fail "git push origin main failed" "retry: git push origin main && git push origin $TAG"
STATE="main pushed (version bump $(short "$SHA")); tag $TAG exists locally but is NOT pushed"
git push -q origin "$TAG" || fail "git push origin $TAG failed" "retry: git push origin $TAG"
STATE="main and tag $TAG pushed"
say "ok: pushed main and $TAG"

# --- 5. find and watch the release.yml run ---------------------------------------------
# GitHub registers the run a few seconds after the push; poll briefly rather than sleep a
# guessed amount. Matching the tag (headBranch) AND the sha rules out a stale run from an
# earlier push of the same tag name.
RERUN="gh workflow run release.yml -R $REPO -f tag=$TAG"
RUN_ID=""; RUN_URL=""
i=0
while [ "$i" -lt 24 ]; do
  run="$(gh run list -R "$REPO" --workflow release.yml --branch "$TAG" -L 1 \
    --json databaseId,headSha,url \
    --jq '.[0] | select(. != null) | [(.databaseId | tostring), .headSha, .url] | join(" ")' \
    2>/dev/null || true)"
  if [ -n "$run" ]; then
    read -r RUN_ID run_sha RUN_URL <<EOR
$run
EOR
    [ "$run_sha" = "$SHA" ] && break
    RUN_ID=""
  fi
  i=$((i + 1)); sleep 5
done
[ -n "$RUN_ID" ] || fail "no release.yml run for $TAG appeared within 120s" \
  "check https://github.com/$REPO/actions/workflows/release.yml; if none ran: $RERUN"
say "ok: release.yml run $RUN_URL"

# gh's own exit code is the verdict; --compact keeps a 20-minute log readable.
gh run watch -R "$REPO" "$RUN_ID" --exit-status --compact --interval 15 >&2 \
  || fail "release.yml failed: $RUN_URL" \
       "fix the cause, then: gh run rerun $RUN_ID -R $REPO --failed (or $RERUN)"
STATE="main and tag $TAG pushed; release.yml succeeded ($RUN_URL)"

# --- 6. download what users download, and check it ------------------------------------
# release.yml verifies its own files before upload; this verifies what the release page
# actually serves. That gap is where v1.5.0/v1.6.0's bad .dmg.sha256 lived.
mkdir -p "$TMP/dl"
for a in "GoblinPortal-$TAG.zip" "GoblinPortal-$TAG.zip.sha256" \
         "GoblinPortal-$TAG.dmg" "GoblinPortal-$TAG.dmg.sha256"; do
  gh release download "$TAG" -R "$REPO" -D "$TMP/dl" -p "$a" --clobber >/dev/null 2>&1 \
    || fail "release asset $a missing or not downloadable" \
         "inspect: gh release view $TAG -R $REPO; re-upload with: $RERUN"
  [ -s "$TMP/dl/$a" ] || fail "release asset $a downloaded empty" "re-upload with: $RERUN"
done
for f in "GoblinPortal-$TAG.zip" "GoblinPortal-$TAG.dmg"; do
  # release.yml writes `<hash>  <bare filename>`. Re-pair the hash with the file we
  # downloaded, so a sidecar that ever carries a runner-side directory prefix still
  # checks these bytes instead of failing on a path that only existed on the runner.
  hash="$(awk 'NR == 1 { print $1 }' "$TMP/dl/$f.sha256")"
  printf '%s\n' "$hash" | grep -Eqx '[0-9a-f]{64}' \
    || fail "$f.sha256 does not start with a sha256 hash" "re-upload with: $RERUN"
  ( cd "$TMP/dl" && printf '%s  %s\n' "$hash" "$f" | shasum -a 256 -c - >/dev/null ) \
    || fail "$f does not match its published .sha256" \
         "the release is LIVE with a bad checksum; re-upload with: $RERUN"
  say "ok: $f matches $f.sha256"
done

# --- 7. done ----------------------------------------------------------------------------
URL="$(gh release view "$TAG" -R "$REPO" --json url --jq .url 2>/dev/null \
  || printf 'https://github.com/%s/releases/tag/%s' "$REPO" "$TAG")"
say ""
say "released $TAG: $URL"
say "next: optionally gh release edit $TAG --notes-file <file>; then the site (RELEASING.md)"
