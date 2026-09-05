#!/usr/bin/env bash
# Regenerate CHANGELOG.md from every published GitHub Release.
#
# The GitHub Releases (created by .github/workflows/release.yml with --generate-notes, grouped by
# label per .github/release.yml) are the source of truth. This flattens them into a committed
# CHANGELOG.md that ships with the web app — Kuulla.Web reads it at runtime for the marketing
# page's "What's new" section (ChangelogProvider), so a private-repo app needs no GitHub token.
#
# release.yml runs this after cutting a release and commits the result to main. Also runnable by
# hand: scripts/generate-changelog.sh [owner/repo] [output-path]
set -euo pipefail

REPO="${1:-two4suited/kuulla}"
OUT="${2:-CHANGELOG.md}"

{
  echo "# Changelog"
  echo
  echo "<!-- Generated from the GitHub Releases by scripts/generate-changelog.sh. Do not edit by hand. -->"
  echo

  gh release list --repo "$REPO" --limit 200 \
    --json tagName,publishedAt,isDraft,isPrerelease \
    --jq 'map(select((.isDraft | not) and (.isPrerelease | not)))
          | sort_by(.publishedAt) | reverse | .[].tagName' |
  while read -r tag; do
    [ -n "$tag" ] || continue
    release="$(gh release view "$tag" --repo "$REPO" --json publishedAt,body)"
    echo "## ${tag#v} — $(jq -r '.publishedAt[:10]' <<<"$release")"
    echo
    jq -r '.body // ""' <<<"$release" |
      sed -E "s/\r$//" |
      awk '
        /^### / { if (seen) print ""; seen = 1; print; next }
        /^[*-] / {
          line = substr($0, 3)
          gsub(/ by @[A-Za-z0-9-]+ in [^ ]+[ \t]*$/, "", line)
          print "- " line
        }
      '
    echo
  done
} > "$OUT"

echo "Wrote $OUT"
