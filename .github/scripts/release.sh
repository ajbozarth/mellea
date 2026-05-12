#!/bin/bash
# Tag and publish a release from the currently checked-out release branch.
#
# Expects the version to already be written to pyproject.toml (bump_version.py
# runs earlier in the workflow; this script does not modify the version).
#
# Env:
#   RELEASE_BRANCH (required) — the release branch name (e.g. release/v0.6).
#                              Guards against accidentally releasing from main.
#   GH_TOKEN       (required) — for gh release create / gh pr create
#   GITHUB_REPOSITORY (required) — owner/repo, used for origin URL and links
#   CHGLOG_FILE    (optional) — path to changelog (default: CHANGELOG.md)
#   ALLOW_MAIN_RELEASE=1 (optional) — bypass the main-branch guard
#
# Behavior:
#   1. Creates tag v${VERSION} and a GitHub release from the checked-out HEAD.
#      Passes --prerelease if VERSION contains rc or .dev.
#   2. Appends a changelog entry to ${CHGLOG_FILE} on the release branch and
#      pushes it.
#   3. Opens a PR from chore/changelog-sync-${VERSION} to main with just the
#      changelog delta. Main is never pushed to directly.

set -e
set -x

if [ -z "${RELEASE_BRANCH:-}" ]; then
    >&2 echo "error: RELEASE_BRANCH env var is required"
    exit 2
fi
if [ "${RELEASE_BRANCH}" = "main" ] && [ "${ALLOW_MAIN_RELEASE:-0}" != "1" ]; then
    >&2 echo "error: refusing to release from main; dispatch against a release/v* branch"
    exit 2
fi

CHGLOG_FILE="${CHGLOG_FILE:-CHANGELOG.md}"

# Pull the version from pyproject.toml — authoritative after bump_version.py ran.
TARGET_VERSION=$(uvx --from=toml-cli toml get --toml-path=pyproject.toml project.version)
TARGET_TAG_NAME="v${TARGET_VERSION}"

# Detect prerelease shape (rc or .dev). Prereleases get a git tag only; the
# tag-push triggers pypi.yml, which gates the PyPI upload on the
# PUBLISH_PRERELEASES repo variable. No GitHub Release is created for
# prereleases. Finals go through the full flow: gh release create (which
# tags, creates the Release object, and emits release:published so
# docs-publish.yml runs), changelog entry, sync PR.
IS_PRERELEASE=0
if [[ "${TARGET_VERSION}" == *rc* ]] || [[ "${TARGET_VERSION}" == *.dev* ]]; then
    IS_PRERELEASE=1
fi

git config --global user.name 'github-actions[bot]'
git config --global user.email 'github-actions[bot]@users.noreply.github.com'

# Configure the remote with the token for pushes.
git remote set-url origin "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"

# Prerelease path: tag and push. That's it. pypi.yml decides whether to
# upload based on PUBLISH_PRERELEASES. docs-publish.yml doesn't fire
# (no release:published event).
if [ "${IS_PRERELEASE}" = "1" ]; then
    git tag "${TARGET_TAG_NAME}"
    git push origin "${TARGET_TAG_NAME}"
    echo "Tagged prerelease ${TARGET_TAG_NAME} (PyPI upload gated on PUBLISH_PRERELEASES in pypi.yml)"
    exit 0
fi

# Final path. gh release create creates the tag and the Release object in
# one step. --generate-notes picks the previous Release as the start; since
# prereleases do not create Releases, the previous Release is the last
# final — so notes span from the previous minor/patch to this one.
gh release create "${TARGET_TAG_NAME}" \
    --target "${RELEASE_BRANCH}" \
    --generate-notes

# Publishes from main (the dev case) would never reach here because all
# dev versions are prereleases; left as defensive guard in case ALLOW_MAIN_RELEASE
# is ever used for a main-based final, which would not need a sync PR to itself.
if [ "${RELEASE_BRANCH}" = "main" ]; then
    echo "Published ${TARGET_TAG_NAME} from main — skipping changelog sync PR"
    exit 0
fi

# Pull the generated notes back locally to update the changelog.
REL_NOTES=$(mktemp)
gh release view "${TARGET_TAG_NAME}" --json body -q ".body" >> "${REL_NOTES}"

# Build the updated changelog.
TMP_CHGLOG=$(mktemp)
RELEASE_URL="$(gh repo view --json url -q ".url")/releases/tag/${TARGET_TAG_NAME}"
printf "## [%s](%s) - %s\n\n" "${TARGET_TAG_NAME}" "${RELEASE_URL}" "$(date -Idate)" >> "${TMP_CHGLOG}"
cat "${REL_NOTES}" >> "${TMP_CHGLOG}"
if [ -f "${CHGLOG_FILE}" ]; then
    printf "\n" | cat - "${CHGLOG_FILE}" >> "${TMP_CHGLOG}"
fi
mv "${TMP_CHGLOG}" "${CHGLOG_FILE}"

# Commit the changelog update to the release branch and push it.
git add "${CHGLOG_FILE}"
git commit -m "docs: update changelog for ${TARGET_TAG_NAME} [skip ci]"
git push origin "${RELEASE_BRANCH}"

# Open a PR against main syncing just the changelog delta. Main is never
# pushed to directly from this script; branch protection applies normally.
SYNC_BRANCH="chore/changelog-sync-${TARGET_VERSION}"
git fetch origin main
git checkout -B "${SYNC_BRANCH}" origin/main
# Pick just the changelog change from the commit we just made on the release branch.
git checkout "${RELEASE_BRANCH}" -- "${CHGLOG_FILE}"
git add "${CHGLOG_FILE}"
git commit -m "docs: sync changelog for ${TARGET_TAG_NAME}"
git push origin "${SYNC_BRANCH}"

gh pr create \
    --base main \
    --head "${SYNC_BRANCH}" \
    --title "docs: sync changelog for ${TARGET_TAG_NAME}" \
    --body "Automated changelog sync from \`${RELEASE_BRANCH}\` after publishing [${TARGET_TAG_NAME}](${RELEASE_URL}).

This PR brings the release-branch CHANGELOG entry back to main so the project root CHANGELOG remains the canonical history across all branches."
