# Releasing Goblin Portal

One command cuts a release: `app/Scripts/cut-release.sh X.Y.Z`. It bumps `VERSION` in
`app/Scripts/make-app-bundle.sh`, commits, tags `vX.Y.Z`, pushes main then the tag, watches
`.github/workflows/release.yml` (gates, build, sign, notarise, publish), then downloads the
four published assets and checks both `.sha256` sidecars against the bytes users get.

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
app/Scripts/cut-release.sh X.Y.Z
```

Run it from the **main checkout**, on `main`. Preflight refuses (exit 1, one line saying
why) unless: no tracked changes (untracked is fine); `HEAD == origin/main` after a fetch;
`X.Y.Z` is strict semver and greater than the current `VERSION`; tag `vX.Y.Z` exists
neither locally nor on origin; no GitHub release `vX.Y.Z`; the latest `checks.yml` run on
main is for HEAD and succeeded. If CI is still running or is for an older commit, wait and
re-run. Exit 2 means the environment (no `gh`/`git`, no network, `gh auth login` needed).

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
| no release.yml run appeared | main and tag pushed | check the Actions tab; if none ran, `gh workflow run release.yml -f tag=vX.Y.Z` |
| release.yml failed | main and tag pushed; maybe a release with no or partial assets | fix the cause, then `gh run rerun <id> --failed` or `gh workflow run release.yml -f tag=vX.Y.Z` (uploads use `--clobber`) |
| asset missing / checksum mismatch | release is **live** and wrong | re-run release.yml for the tag as above; if the bytes are bad, consider `gh release edit vX.Y.Z --draft=true` while you fix it |

Never move or delete a pushed tag to "retry": the workflow builds whatever the tag points
at, and clients may already have seen it. If a version is burned, cut the next patch.
