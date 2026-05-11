# RELEASE.md

## Overview

Mellea uses a release-branch workflow. Every minor version has a long-lived
`release/vX.Y` branch that carries release candidates, the final minor release,
and any subsequent patch releases. `main` carries `.dev`-versioned work for the
next minor.

This gives each release a frozen codebase without requiring cherry-picks back
into `main`, and keeps CD resilient to concurrent merges on `main`.

## Release Cadence

Minor releases target a roughly 4-week cadence. Patch releases happen as
needed.

## Versioning

Versions follow **[PEP 440](https://peps.python.org/pep-0440/)** (which is
compatible with SemVer for final releases).

| Phase | Branch | Version example | Tag |
|-------|--------|-----------------|-----|
| Dev on main | `main` | `0.6.0.dev0` | (untagged) |
| Release branch cut | `release/v0.6` | `0.6.0rc0` | `v0.6.0rc0` |
| Further RCs | `release/v0.6` | `0.6.0rc1`, `rc2`, … | `v0.6.0rcN` |
| Final minor | `release/v0.6` | `0.6.0` | `v0.6.0` |
| Patch RC | `release/v0.6` | `0.6.1rc0` | `v0.6.1rc0` |
| Patch final | `release/v0.6` | `0.6.1` | `v0.6.1` |
| Next minor dev on main | `main` | `0.7.0.dev0` | (untagged) |

Invariants:

- `main` always carries `X.Y.0.devN`. `main` is never tagged.
- Release branches always carry `X.Y.Zrc?` or `X.Y.Z`.
- Release candidates and `.dev` versions are published as GitHub pre-releases
  (`gh release create --prerelease`). Pre-releases are hidden from default
  `pip install mellea`; users opt in with `pip install --pre mellea`.

## Workflows

| Workflow | Purpose |
|----------|---------|
| `cut-release-branch` | Cut `release/vX.Y` from `main`, bump `main` to next minor `.dev0` |
| `cd` | Publish a release (tag + GitHub release + PyPI + changelog-sync PR) |
| `cherry-pick-to-release` | Cherry-pick commits from `main` onto a release branch |

All three are `workflow_dispatch`-only and run from the GitHub Actions UI.

## Cutting a minor release branch

When `main` is ready to freeze for the next minor:

1. Go to **Actions → Cut release branch → Run workflow**.
2. Optionally enter the expected minor (e.g. `0.6`) in `confirm_minor` as a
   safety check. Leave blank to trust whatever is in `pyproject.toml` on
   `main`.
3. Run.

The workflow:

- Verifies `pyproject.toml` on `main` matches `X.Y.0.devN`.
- Creates `release/vX.Y` with version set to `X.Y.0rc0`.
- Pushes `main` with version bumped to `X.(Y+1).0.dev0`.

The `main` push requires the release GH App to be listed as a bypass actor in
the `main` branch-protection ruleset (see **Branch protection** below).

## Publishing a release candidate

Once a release branch exists:

1. Go to **Actions → Run CD → Run workflow**.
2. Select the release branch (e.g. `release/v0.6`) from the branch picker.
3. Choose `bump_type: rc`.
4. Run.

The workflow:

- Computes the next rc (e.g. `0.6.0rc0` → `0.6.0rc1`).
- Commits the bump to the release branch.
- Creates tag `v{version}`, a GitHub pre-release, and publishes to PyPI.
- Appends to `CHANGELOG.md` on the release branch.
- Opens a PR against `main` syncing the changelog entry.

Merge the changelog-sync PR at your convenience.

## Promoting an RC to a final minor

When testing on an RC is complete:

1. **Actions → Run CD → Run workflow** against the same release branch.
2. `bump_type: final`.
3. Run.

This tags `v0.6.0`, publishes a non-prerelease GitHub release (no
`--prerelease` flag), uploads to PyPI as the latest, and triggers the docs
production deploy.

## Patch releases

Patches live on the original release branch; they never touch `main` directly
except via the changelog-sync PR.

### 1. Cherry-pick fixes

1. Identify the commit SHAs on `main` that need to go into the patch.
2. **Actions → Cherry-pick to release branch → Run workflow**.
3. `target_branch`: `release/v0.6`; `shas`: space- or comma-separated SHAs.
4. Run.

The workflow topologically sorts the SHAs by their position in `git log main`,
cherry-picks with `git cherry-pick -x`, and pushes directly to the release
branch (the GH App needs bypass on `release/**`). CI runs on the push.

If the workflow hits a conflict it fails with a resolution playbook. To
resolve:

```bash
git fetch origin
git checkout release/v0.6
git reset --hard origin/release/v0.6
./.github/scripts/cherry_pick_to_release.sh release/v0.6 <sha> [<sha> ...]
# Resolve conflicts:
git add <resolved-files>
git cherry-pick --continue
git push origin release/v0.6
```

Requires push access to `release/**` (or bypass).

### 2. Publish a patch RC and final

1. **Run CD** against `release/v0.6` with `bump_type: patch-rc`. Produces
   e.g. `v0.6.1rc0`.
2. Test.
3. **Run CD** again with `bump_type: patch-rc` for additional rcs if needed.
4. **Run CD** with `bump_type: patch-final` to promote to `v0.6.1`.

## Rollback and retry

If a CD run fails partway through — e.g. PyPI upload failed but the tag was
already created — the `bump_type: none` option re-runs CD against whatever
version is currently in `pyproject.toml`, skipping the bump step. Useful for
resuming a stuck release.

## Release branch retention

**Release branches are never deleted.** GitHub Releases pin to specific
commits on each branch, so pruning a branch would orphan those references and
break `git checkout v0.4.2` semantics. Old `release/v0.3`, `release/v0.4`, etc.
stay around indefinitely.

## Branch protection

The release GH App (configured via `CI_APP_ID` / `CI_PRIVATE_KEY`) needs bypass
rights on two rulesets:

- `main`: the `cut-release-branch` workflow pushes the `X.(Y+1).0.dev0` bump
  directly.
- `release/**`: the `cd` workflow pushes the version-bump commit, and
  `cherry-pick-to-release` pushes cherry-picked commits directly.

Recommended ruleset for `release/**`:

- Require pull request review (bypassable by the release GH App).
- Require status checks to pass (CI).
- No force-push, no deletion.

Docs publishing (`docs-publish.yml`) deploys to `docs/production` only when a
published GitHub release is both (a) not a pre-release and (b) the latest
final by semver. RC releases and older-branch patches do not overwrite
production docs.

## Docs behavior by release type

| Release type | docs/production | docs/staging |
|--------------|-----------------|--------------|
| RC (`v0.6.0rc0`) | unchanged | unchanged |
| Final minor (`v0.6.0`) | deployed | (main-push rebuilds as usual) |
| Patch on latest minor (`v0.6.1` after `v0.6.0`) | deployed | unchanged |
| Patch on older minor (`v0.5.1` after `v0.6.0`) | unchanged | unchanged |

Versioned docs (per-minor URL prefixes and a version switcher) is the proper
long-term fix; see follow-up issue.
