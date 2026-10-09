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
#   app/Scripts/cut-release.sh X.Y.Z --resume    # after timeout or manual dispatch: find the
#                                                 # run, watch it, verify assets, print the URL.
#                                                 # Skips steps 1-4 (bump/commit/tag/push);
#                                                 # tag must already exist on origin.
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
NEW=""; DRY=0; RESUME=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    --resume)  RESUME=1 ;;
    -h|--help) sed -n '3,28p' "$0"; exit 0 ;;
    -*) refuse "unknown flag $arg (usage: cut-release.sh X.Y.Z [--dry-run|--resume])" ;;
    *) [ -z "$NEW" ] || refuse "more than one version given"; NEW="$arg" ;;
  esac
done
[ -n "$NEW" ] || refuse "usage: cut-release.sh X.Y.Z [--dry-run|--resume]"
[ "$DRY" -eq 0 ] || [ "$RESUME" -eq 0 ] || refuse "--dry-run and --resume are mutually exclusive"

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=cut-release-preflight.sh
# Defines: is_semver, semver_gt, short (helpers), and preflight (the whole pre-write gate).
. "$HERE/cut-release-preflight.sh"
is_semver "$NEW" || refuse "'$NEW' is not strict semver X.Y.Z (no leading v, no suffix)"
TAG="v$NEW"
CUR=""

# Tool-presence + gh version gate: runs before any direct tool use, so a missing
# or outdated tool gets a clean exit 2 (not a noisy shell error) on the next line.
_preflight_tools
cd "$(git -C "$HERE" rev-parse --show-toplevel)" || env_fail "not inside a git checkout"

# A tag pushed anywhere but GitHub never triggers release.yml. Refused for real runs;
# a dry run only warns, so it can be rehearsed in a throwaway clone.
ORIGIN_URL="$(git remote get-url origin)"
case "$ORIGIN_URL" in
  *[/@]github.com[:/]"$REPO"|*[/@]github.com[:/]"$REPO".git) ORIGIN_OK=1 ;;
  *) ORIGIN_OK=0 ;;
esac

# --- --resume path: adopt a late or manually-dispatched run -------------------------
# Skips all write steps (bump/commit/tag/push). The tag must already exist on origin.
# Finds the most-recent release.yml run whose trigger input tag OR headBranch matches
# $TAG — covering both a delayed tag-push event and a manual `gh workflow run`.
if [ "$RESUME" -eq 1 ]; then
  [ "$ORIGIN_OK" -eq 1 ] || refuse "origin is $ORIGIN_URL, not github.com/$REPO"
  command -v gh >/dev/null 2>&1 || env_fail "gh not found on PATH (https://cli.github.com)"
  gh auth status -h github.com >/dev/null 2>&1 || env_fail "gh is not authenticated (gh auth login)"

  # Confirm the tag is on origin; a missing tag means there is nothing to resume.
  rc=0; git fetch --quiet --tags origin 2>/dev/null || rc=$?
  [ "$rc" -eq 0 ] || env_fail "git fetch --tags origin failed (network or auth?)"
  git rev-parse -q --verify "refs/tags/$TAG" >/dev/null \
    || refuse "tag $TAG does not exist on origin — nothing to resume (run without --resume to cut fresh)"
  SHA="$(git rev-parse "refs/tags/$TAG")"
  STATE="tag $TAG exists on origin; resuming watch (no local changes made)"

  TMP="$(mktemp -d)"
  _find_run
  [ -n "$RUN_ID" ] || fail "no release.yml run for $TAG found after 120s" \
    "check https://github.com/$REPO/actions/workflows/release.yml; to start one: gh workflow run release.yml -R $REPO -f tag=$TAG; then re-run: cut-release.sh $NEW --resume"

  say "ok: adopting release.yml run $RUN_URL"
  RERUN="gh workflow run release.yml -R $REPO -f tag=$TAG"
  gh run watch -R "$REPO" "$RUN_ID" --exit-status --compact --interval 15 >&2 \
    || fail "release.yml failed: $RUN_URL" \
         "fix the cause, then: gh run rerun $RUN_ID -R $REPO --failed (or $RERUN)"
  STATE="tag $TAG on origin; release.yml succeeded ($RUN_URL)"
  _verify_assets
  URL="$(gh release view "$TAG" -R "$REPO" --json url --jq .url 2>/dev/null \
    || printf 'https://github.com/%s/releases/tag/%s' "$REPO" "$TAG")"
  say ""
  say "released $TAG: $URL"
  say "next: optionally gh release edit $TAG --notes-file <file>; then the site (RELEASING.md)"
  exit 0
fi

preflight

if [ "$DRY" -eq 1 ]; then
  [ "$ORIGIN_OK" -eq 1 ] || say "warning: origin is $ORIGIN_URL, not $REPO; a real run would refuse"
  say ""
  say "dry run: preflight passed; a real run would:"
  say "  1. rewrite $BUNDLE_REL: VERSION=\"$CUR\" -> VERSION=\"$NEW\" (assert one line changed)"
  say "  2. git commit -m 'chore(app): bump version to $NEW' (as AFK Agent <agent@agentafk.com>)"
  say "  3. git tag $TAG on that commit"
  say "  4. git push origin main, then git push origin $TAG"
  say "  5. find the release.yml run for $TAG (tag-push or workflow_dispatch) and gh run watch --exit-status"
  say "  6. download GoblinPortal-$TAG.{zip,dmg} + .sha256 and shasum -a 256 -c both"
  say "  7. print the release URL"
  say "  (if step 5 times out: cut-release.sh $NEW --resume  picks up where it left off)"
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
# A tag push triggers the workflow with headBranch == the tag name. A manual
# workflow_dispatch uses headBranch == the branch it was dispatched from (usually main).
# _find_run checks both so a delayed push event or an operator-dispatched run are both
# adopted — the v1.9.0 incident produced exactly the latter.
RERUN="gh workflow run release.yml -R $REPO -f tag=$TAG"
RUN_ID=""; RUN_URL=""
_find_run
[ -n "$RUN_ID" ] || fail "no release.yml run for $TAG appeared within 120s" \
  "check https://github.com/$REPO/actions/workflows/release.yml; to start one manually: $RERUN; then watch with: cut-release.sh $NEW --resume"
say "ok: release.yml run $RUN_URL"

# gh's own exit code is the verdict; --compact (gh >= 2.74.0, cli/cli PR #10629) keeps
# a 20-minute log readable. Version already gated in preflight(); no re-check needed here.
gh run watch -R "$REPO" "$RUN_ID" --exit-status --compact --interval 15 >&2 \
  || fail "release.yml failed: $RUN_URL" \
       "fix the cause, then: gh run rerun $RUN_ID -R $REPO --failed (or $RERUN)"
STATE="main and tag $TAG pushed; release.yml succeeded ($RUN_URL)"

# --- 6. download what users download, and check it ------------------------------------
# release.yml verifies its own files before upload; this verifies what the release page
# actually serves. That gap is where v1.5.0/v1.6.0's bad .dmg.sha256 lived.
_verify_assets

# --- 7. done ----------------------------------------------------------------------------
URL="$(gh release view "$TAG" -R "$REPO" --json url --jq .url 2>/dev/null \
  || printf 'https://github.com/%s/releases/tag/%s' "$REPO" "$TAG")"
say ""
say "released $TAG: $URL"
say "next: optionally gh release edit $TAG --notes-file <file>; then the site (RELEASING.md)"
