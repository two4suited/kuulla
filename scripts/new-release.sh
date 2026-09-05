#!/usr/bin/env bash
# Cut a release tag (milestone #37). Kuulla releases are identified by a CalVer tag
#
#     vYYYY.M.N
#
# where YYYY is the UTC year, M is the UTC month with no leading zero, and N is a
# zero-based counter of releases within that calendar month, resetting to 0 each month.
# First release in Sept 2026 is v2026.9.0; the next is v2026.9.1; the first in Oct is
# v2026.10.0.
#
# Pushing that tag is the release trigger for everything else in the milestone:
# release.yml turns it into a GitHub Release with auto-generated notes, and deploy.yml
# deploys the tagged commit. Releases are cut from `main` only, so this script refuses
# to run unless HEAD is exactly at origin/main with a clean tree.
#
# Usage: scripts/new-release.sh [-n|--dry-run]
#   -n, --dry-run   Compute and print the tag and commit range, then stop.
#
# Honors $REMOTE (default: origin).
set -euo pipefail

remote="${REMOTE:-origin}"
dry_run=false

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--dry-run) dry_run=true ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
  shift
done

for dependency in git; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    echo "Missing dependency: $dependency" >&2
    exit 1
  fi
done

# Get an authoritative view of main and every existing tag before computing anything.
git fetch --quiet "$remote" main --tags

if [ -n "$(git status --porcelain)" ]; then
  echo "Working tree is not clean. Releases are cut from a pristine main checkout." >&2
  exit 1
fi

head_sha=$(git rev-parse HEAD)
main_sha=$(git rev-parse "$remote/main")
if [ "$head_sha" != "$main_sha" ]; then
  echo "HEAD ($(git rev-parse --short HEAD)) is not at $remote/main ($(git rev-parse --short "$remote/main"))." >&2
  echo "Check out main and pull before cutting a release." >&2
  exit 1
fi

year=$(date -u +%Y)
month=$((10#$(date -u +%m)))
prefix="v${year}.${month}."

# Highest N already used this month (numeric sort; 10 must sort above 9).
highest=$(git tag -l "${prefix}*" | sed "s|^${prefix}||" | grep -E '^[0-9]+$' | sort -n | tail -1 || true)
if [ -z "$highest" ]; then
  next_n=0
else
  next_n=$((highest + 1))
fi
new_tag="${prefix}${next_n}"

if git rev-parse -q --verify "refs/tags/${new_tag}" >/dev/null; then
  echo "Tag ${new_tag} already exists. Refusing to overwrite." >&2
  exit 1
fi

# Previous release across all months, for the changelog range.
prev_tag=$(git tag -l 'v*' --sort=-v:refname | head -1 || true)

echo "New release tag:  ${new_tag}"
echo "Target commit:    $(git rev-parse --short HEAD) $(git log -1 --format=%s)"
if [ -n "$prev_tag" ]; then
  echo "Previous tag:     ${prev_tag}"
  echo
  echo "Commits since ${prev_tag}:"
  git log --oneline --no-decorate "${prev_tag}..HEAD"
  commit_count=$(git rev-list --count "${prev_tag}..HEAD")
  echo
  echo "(${commit_count} commit(s))"
else
  echo "Previous tag:     (none — this is the first release)"
  echo
  echo "Recent commits:"
  git log --oneline --no-decorate -20 HEAD
fi

if [ "$dry_run" = true ]; then
  echo
  echo "Dry run — no tag created."
  exit 0
fi

echo
printf 'Create and push %s to %s? [y/N] ' "$new_tag" "$remote"
read -r reply
case "$reply" in
  y|Y|yes|YES) ;;
  *) echo "Aborted."; exit 1 ;;
esac

git tag -a "$new_tag" -m "Release $new_tag"
git push "$remote" "refs/tags/${new_tag}"

echo "Pushed ${new_tag}. release.yml will publish the GitHub Release and deploy.yml will deploy this commit."
