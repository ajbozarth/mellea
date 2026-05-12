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

- `main` always carries `X.Y.0.devN`. `main` is tagged only when a dev
  publication runs (`publish-dev-from-main` workflow); never during routine
  commits.
- Release branches always carry `X.Y.Zrc?` or `X.Y.Z`.
- Prereleases (`rcN`, `.devN`) always receive a git tag. Whether they
  additionally produce a GitHub Release + PyPI upload is controlled by the
  `PUBLISH_PRERELEASES` repo variable (see below).

## The `PUBLISH_PRERELEASES` flag

Prerelease publishing behavior is governed by the repo variable
`PUBLISH_PRERELEASES` (default: `false`, unset is treated as false).

| `PUBLISH_PRERELEASES` | What happens for rc / dev | Finals |
|-----------------------|---------------------------|--------|
| `false` (default) | tag + push (no GH Release, no PyPI) | tag + GitHub Release + PyPI + changelog entry + sync PR |
| `true` | tag + push + PyPI upload (still no GH Release) | tag + GitHub Release + PyPI + changelog entry + sync PR |

Prereleases never get a GitHub Release object, regardless of the flag. The
flag only gates PyPI upload. This keeps the Releases tab scoped to
user-facing milestones and keeps `CHANGELOG.md` free of per-rc noise — the
full release flow with notes, changelog, and sync PR runs only for finals.

Because only finals create a GitHub Release, `gh release create --generate-notes`
on a final naturally picks the previous **final** as the start tag — so
notes span from the previous minor/patch to this one, not just from the
most recent rc.

Tags are always pushed regardless. Users can install any tagged prerelease
via `pip install git+https://github.com/generative-computing/mellea@v0.6.0rc1`
whether or not the flag is enabled.

Finals (`X.Y.0`, `X.Y.Z`) always follow the full release flow regardless of
the flag — that's the user-facing path.

To enable prerelease publishing later, a repo admin sets the variable to
`true` under **Settings → Secrets and variables → Actions → Variables**.
No code change needed.

## Workflows

| Workflow | Purpose |
|----------|---------|
| `cut-release-branch` | Cut `release/vX.Y` from `main`, publish `X.Y.0rc0`, bump `main` to next minor `.dev0` |
| `cd` | Publish a release (rc, final, patch-rc, patch-final, or retry a failed publish) |
| `cherry-pick-to-release` | Cherry-pick commits from `main` onto a release branch |
| `publish-dev-from-main` | Iterate main's `.devN` counter and publish a dev release |

All four are `workflow_dispatch`-only and run from the GitHub Actions UI.

Whether any given prerelease (`rc`, `dev`) produces a PyPI artifact depends
on the `PUBLISH_PRERELEASES` flag described above.

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
- **Publishes `X.Y.0rc0`** per the `PUBLISH_PRERELEASES` flag — tag-only by
  default, or full release + PyPI if the flag is enabled. rc0 is treated
  identically to subsequent rcs; it is not a placeholder.
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

## Publishing a dev release from main

Ad-hoc, case-by-case `.devN` bumps on `main`. Typical uses: a contributor
wants a tagged snapshot of main for debugging, an external tester needs a
specific point-in-time artifact, etc. Not intended for routine or scheduled
releases.

1. **Actions → Publish dev release from main → Run workflow** (must dispatch
   against `main`).
2. Run.

The workflow (publish-then-increment):

1. Publishes `main`'s **current** `.devN` per `PUBLISH_PRERELEASES` — tag-only
   by default, full release flow if enabled. The tag points at the current
   `main` HEAD.
2. Iterates pyproject on main: `X.Y.Z.devN → X.Y.Z.dev(N+1)`, commits, pushes.

The invariant is that `main`'s pyproject always carries "the next version
that would be published." Inspecting main tells you what the next dispatch
will produce.

If `PUBLISH_PRERELEASES=false` (current default), the outcome is a git tag
like `v0.7.0.dev3` pointing at `main` HEAD and no other external effects. If
`PUBLISH_PRERELEASES=true`, the tag is accompanied by a GitHub Release (marked
pre-release) and a PyPI upload installable via `pip install --pre mellea`.
Dev publishes never touch `CHANGELOG.md` (prerelease behavior, regardless of
flag).

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
