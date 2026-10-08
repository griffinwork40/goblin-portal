# shellcheck shell=bash
# Sourced by cut-release.sh -- never run on its own. The PREFLIGHT half of a release:
# every check that must pass before anything is written, committed, or pushed.
#
# Split out of cut-release.sh on the seam between "is it safe to start?" and "do it",
# the same shape as verify-vendor.sh / verify-vendor-views.sh: this file inherits
# REPO, TAG, NEW, BUNDLE_REL and the say / refuse / env_fail helpers from its caller,
# and its exits are the caller's exits (1 = refused, 2 = environmental).
#
# Ordering is deliberate: cheap LOCAL refusals first (branch, clean tree), then the
# network (fetch, ls-remote, gh), so a wrong-branch run refuses identically on a plane.

# --- strict semver, and strictly newer than what the bundle says --------------------
# The case guard runs before grep because grep is line-oriented: "1.2.3<newline>x"
# would otherwise match on its first line and pass.
is_semver() {
  case "$1" in ''|*[!0-9.]*) return 1 ;; esac
  printf '%s\n' "$1" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
}

# Numeric, component by component. A string compare says "1.10.0" < "1.9.0", which is
# the exact trap check-update-logic.sh pins for UpdateChecker.isNewer; a release script
# that disagreed with the app's own updater would mint versions no client offers.
# Leading zeros are already refused by is_semver, so `[ -gt ]` never sees octal.
semver_gt() {
  local a1 a2 a3 b1 b2 b3
  IFS=. read -r a1 a2 a3 <<EOF
$1
EOF
  IFS=. read -r b1 b2 b3 <<EOF
$2
EOF
  if [ "$a1" -ne "$b1" ]; then [ "$a1" -gt "$b1" ]; return; fi
  if [ "$a2" -ne "$b2" ]; then [ "$a2" -gt "$b2" ]; return; fi
  [ "$a3" -gt "$b3" ]
}

short() { printf '%.7s' "$1"; }

# Standalone tool-presence check, called before any direct tool use in cut-release.sh.
# preflight() re-checks as well, so the two stay in sync automatically.
_preflight_tools() {
  command -v git   >/dev/null 2>&1 || env_fail "git not found on PATH"
  command -v gh    >/dev/null 2>&1 || env_fail "gh not found on PATH (https://cli.github.com)"
  command -v shasum >/dev/null 2>&1 || env_fail "shasum not found on PATH"

  # gh >= 2.74.0 is required for 'gh run watch --compact' (cli/cli PR #10629, gh v2.74.0, 2025-05-29).
  # Check here in preflight so an outdated gh exits 2 before any write.
  local _v
  _v="$(gh --version 2>/dev/null | awk 'NR==1{print $3}')"
  is_semver "$_v" || env_fail "could not parse gh version (found '${_v:-unknown}'; upgrade: https://cli.github.com)"
  semver_gt "$_v" "2.73.99" \
    || env_fail "gh >= 2.74.0 required for 'gh run watch --compact' (found $_v; upgrade: https://cli.github.com)"
}

preflight() {
  local branch head origin_head n cur rc hits ci sha status conclusion url

  command -v git >/dev/null 2>&1 || env_fail "git not found on PATH"
  command -v gh >/dev/null 2>&1 || env_fail "gh not found on PATH (https://cli.github.com)"
  command -v shasum >/dev/null 2>&1 || env_fail "shasum not found on PATH"

  # gh >= 2.74.0 required for 'gh run watch --compact' (cli/cli PR #10629, gh v2.74.0, 2025-05-29).
  local _v
  _v="$(gh --version 2>/dev/null | awk 'NR==1{print $3}')"
  is_semver "$_v" || env_fail "could not parse gh version (found '${_v:-unknown}'; upgrade: https://cli.github.com)"
  semver_gt "$_v" "2.73.99" \
    || env_fail "gh >= 2.74.0 required for 'gh run watch --compact' (found $_v; upgrade: https://cli.github.com)"

  # --- local state: branch and tree ---------------------------------------------------
  branch="$(git symbolic-ref --short -q HEAD || true)"
  [ "$branch" = "main" ] || refuse "not on main (on '${branch:-detached HEAD}'); run from the main checkout"
  # Untracked files are fine (scratch notes, .afk/tmp); a tracked edit is not, because
  # `git commit` below must contain the VERSION bump and nothing else.
  [ -z "$(git status --porcelain --untracked-files=no)" ] \
    || refuse "working tree has tracked changes; commit or stash them first"
  say "ok: on main, no tracked changes"

  # --- local main is exactly origin's main ----------------------------------------------
  git fetch --quiet --tags origin || env_fail "git fetch --tags origin failed (network or auth?)"
  head="$(git rev-parse HEAD)"
  origin_head="$(git rev-parse -q --verify refs/remotes/origin/main || true)"
  [ -n "$origin_head" ] || refuse "origin/main does not exist after fetch"
  [ "$head" = "$origin_head" ] \
    || refuse "HEAD $(short "$head") != origin/main $(short "$origin_head"); pull or push first"
  say "ok: HEAD == origin/main ($head)"

  # --- version: one VERSION= line, and the new one is strictly greater ----------------
  # release.yml reads the same line with `grep -m1 '^VERSION='`; two lines would mean
  # the bump could edit one while CI reads the other.
  n="$(grep -c '^VERSION=' "$BUNDLE_REL" || true)"
  [ "$n" = "1" ] || refuse "$BUNDLE_REL has $n VERSION= lines, expected exactly 1"
  cur="$(grep '^VERSION=' "$BUNDLE_REL" | cut -d'"' -f2)"
  is_semver "$cur" || refuse "current VERSION '$cur' in $BUNDLE_REL is not X.Y.Z"
  semver_gt "$NEW" "$cur" || refuse "$NEW is not greater than current VERSION $cur"
  # shellcheck disable=SC2034  # CUR is read by cut-release.sh for the dry-run plan
  CUR="$cur"
  say "ok: $NEW > $cur"

  # --- the tag is free, locally and on origin -------------------------------------------
  git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && refuse "tag $TAG already exists locally"
  # ls-remote --exit-code: 0 = found, 2 = no match; anything else is the network.
  rc=0; git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] && refuse "tag $TAG already exists on origin"
  [ "$rc" -eq 2 ] || env_fail "git ls-remote origin failed (exit $rc)"
  say "ok: tag $TAG absent locally and on origin"

  # --- GitHub: authenticated, no release by that tag or title ---------------------------
  # Every gh call names the repo with -R rather than trusting the remote, so a fork or a
  # local clone cannot point this at the wrong project.
  gh auth status -h github.com >/dev/null 2>&1 || env_fail "gh is not authenticated (gh auth login)"
  # Drafts included: a draft named vX.Y.Z would make release.yml's `gh release view`
  # see an existing release and upload into it instead of creating a public one.
  hits="$(gh release list -R "$REPO" -L 1000 --json tagName,name \
    --jq ".[] | select(.tagName == \"$TAG\" or .name == \"$TAG\") | .tagName")" \
    || env_fail "gh release list failed (network?)"
  [ -z "$hits" ] || refuse "a GitHub release named $TAG already exists"
  say "ok: no GitHub release $TAG"

  # --- CI: the latest checks.yml run on main is THIS commit, and it is green ------------
  # release.yml re-runs the gates on the tag anyway; this check exists so a red main is
  # caught before a version number is burned on it, not 20 minutes into a release run.
  ci="$(gh run list -R "$REPO" --workflow checks.yml --branch main -L 1 \
    --json headSha,status,conclusion,url \
    --jq '.[0] | [.headSha, .status, (.conclusion | if . == "" or . == null then "none" else . end), .url] | join(" ")')" \
    || env_fail "gh run list failed (network?)"
  [ -n "$ci" ] || refuse "no checks.yml run found on main"
  read -r sha status conclusion url <<EOF
$ci
EOF
  [ "$sha" = "$head" ] || refuse "latest checks.yml run on main is for $(short "$sha"), not HEAD $(short "$head") (CI not started yet?): $url"
  [ "$status" = "completed" ] || refuse "checks.yml on HEAD is still $status: $url"
  [ "$conclusion" = "success" ] || refuse "checks.yml on HEAD concluded '$conclusion': $url"
  say "ok: checks.yml green on HEAD ($url)"
}
