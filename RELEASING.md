# Releasing Goblin Portal

One command cuts a release: `app/Scripts/cut-release.sh X.Y.Z`. It bumps `VERSION` in
`app/Scripts/make-app-bundle.sh`, commits, tags `vX.Y.Z`, pushes main then the tag, watches
`.github/workflows/release.yml` (gates, build, sign, notarise, publish), then downloads the
four published assets and checks both `.sha256` sidecars against the bytes users get.

If the watch times out or a run was started manually, use `--resume` to re-attach (see
"If it fails partway" below) — it finds both tag-push and `workflow_dispatch` runs.

## When to cut

Cut when **both** hold:

- main has **user-visible** changes since the last tag. Check with
  `git log --oneline $(git describe --tags --abbrev=0)..origin/main`. Docs, gates, CI and
  `.afk/` notes alone are not a release.
- main's CI is green on HEAD (the script refuses otherwise, see below).

## Which number

Read the commits since the last tag, not the diff size.

| Bump  | When |
|-------|------|
| patch `X.Y.Z+1` | fixes only: nothing a user could newly *do* or *see* |
| minor `X.Y+1.0` | any user-visible feature, setting, menu item, or changed default |
| major | reserved; not used for ordinary releases |

When a release mixes fixes and one feature, it is a minor. The in-app updater compares
versions numerically (`UpdateChecker.isNewer`), and so does the script: `1.10.0 > 1.9.0`.

## The command

```sh
app/Scripts/cut-release.sh X.Y.Z --dry-run   # always first: preflight + the plan, writes nothing
app/Scripts/cut-release.sh X.Y.Z             # do it
app/Scripts/cut-release.sh X.Y.Z --resume    # re-attach after timeout or manual dispatch
```

Run it from the **main checkout**, on `main`. Preflight refuses (exit 1, one line saying
why) unless: no tracked changes (untracked is fine); `HEAD == origin/main` after a fetch;
`X.Y.Z` is strict semver and greater than the current `VERSION`; tag `vX.Y.Z` exists
neither locally nor on origin; no GitHub release `vX.Y.Z`; the latest `checks.yml` run on
main is for HEAD and succeeded. If CI is still running or is for an older commit, wait and
re-run. Exit 2 means the environment (no `gh`/`git`, no network, `gh auth login` needed).

`--resume` skips the bump/commit/tag/push steps and goes straight to finding the
release.yml run for the tag. It searches for both tag-push runs (where `headBranch`
is the tag) and `workflow_dispatch` runs (where `headBranch` is whatever branch the
dispatch was started from, usually main). Once the run is found it watches, verifies
assets, and prints the release URL — the same ending as a normal run.

## After it succeeds

1. Optional: replace the generated notes with hand-written ones:
   `gh release edit vX.Y.Z --notes-file notes.md`
2. Update the marketing site, `griffinwork40/umber-site`. Once its "derive download
   version/URL/size from GitHub Releases API" PR has landed, version, DMG URL, and size
   come from the GitHub API, so only the "what's new" entry in `src/lib/release.ts` needs
   editing (plus FAQ wording, if it names a version). That is a separate PR in that repo.

## If it fails partway

The script prints `state left:` and `next:` lines on every failure. By stage:

| Failed at | State | Do |
|-----------|-------|----|
| preflight | nothing changed | fix the reason it printed, re-run |
| bump/commit/tag (local) | local edit, or local commit + tag, nothing pushed | `git tag -d vX.Y.Z; git reset --hard origin/main`, re-run |
| `git push origin main` | local commit + tag only | `git push origin main && git push origin vX.Y.Z`, then watch release.yml by hand |
| `git push origin vX.Y.Z` | main has the bump, tag not pushed | `git push origin vX.Y.Z`; do **not** re-run the script (VERSION already bumped) |
| no release.yml run appeared | main and tag pushed | `cut-release.sh X.Y.Z --resume` (polls for both tag-push and dispatch runs for 120s); or manually: `gh workflow run release.yml -f tag=vX.Y.Z`, then `cut-release.sh X.Y.Z --resume` |
| release.yml failed | main and tag pushed; maybe a release with no or partial assets | fix the cause, then `gh run rerun <id> --failed` or `gh workflow run release.yml -f tag=vX.Y.Z`, then `cut-release.sh X.Y.Z --resume` (uploads use `--clobber`) |
| asset missing / checksum mismatch | release is **live** and wrong | re-run release.yml for the tag as above; if the bytes are bad, consider `gh release edit vX.Y.Z --draft=true` while you fix it |

Never move or delete a pushed tag to "retry": the workflow builds whatever the tag points
at, and clients may already have seen it. If a version is burned, cut the next patch.

## Duplicate runs for the same tag

`release.yml` has a concurrency guard keyed on the tag (`release-vX.Y.Z`). If a delayed
tag-push event and a manual `gh workflow run` both arrive, the first run proceeds and the
second queues behind it. `cancel-in-progress: false` is intentional — cancelling a run
mid-publish could leave a release with the zip uploaded but not the DMG. The second run
starts only after the first finishes; an idempotency check at the top of the release job
then detects that all four assets are already published and exits early without rebuilding.

If you see two runs for the same tag in the Actions tab, this is expected behaviour.
`--resume` will adopt whichever run is in progress or most recent.

**v1.9.0 post-mortem**: a delayed tag-push event arrived after an operator had already
started a manual `workflow_dispatch` for the same tag. Both ran concurrently toward
`gh release upload`, and `cut-release.sh` failed with "no release.yml run appeared"
because it only searched for runs with `headBranch == tag` (the tag-push shape). The
`workflow_dispatch` run had `headBranch == main` and was invisible to the poll. Fixed by:
the concurrency guard (queues duplicates rather than cancelling), the idempotency check
(second run exits 0 if assets are complete), and `--resume` plus the wider poll in
`_find_run` (adopts both trigger shapes).
