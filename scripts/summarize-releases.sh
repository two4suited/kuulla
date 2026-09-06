#!/usr/bin/env bash
# Write a short, plain-language "what's new" blurb for each release, using the `claude` CLI.
#
# CHANGELOG.md (regenerated from the GitHub Releases by scripts/generate-changelog.sh) is a flat
# list of merged-PR titles grouped by label — accurate, but it reads like a dev changelog on the
# marketing page. This distills each release into a sentence or two aimed at a listener and
# stores the result in release-summaries.json, keyed by version. Kuulla.Web ships that file and
# renders the blurb as the lead line of each "What's new" entry, with the raw grouped notes
# tucked into a "Full notes" expander (see ChangelogProvider / Landing.razor).
#
# Run it by hand after CHANGELOG.md updates — the release runbook's "Summaries" step calls for it
# once the release.yml changelog commit has landed on main:
#   scripts/summarize-releases.sh                 # fill in any releases that lack a blurb
#   scripts/summarize-releases.sh --only 2026.9.3 # (re)summarize just this one
#   scripts/summarize-releases.sh --force         # redo every release
#
# Honors $CHANGELOG (default CHANGELOG.md), $OUT (default release-summaries.json), and
# $KUULLA_SUMMARY_MODEL (default: sonnet — passed to `claude --model`).
set -euo pipefail

CHANGELOG="${CHANGELOG:-CHANGELOG.md}"
OUT="${OUT:-release-summaries.json}"
MODEL="${KUULLA_SUMMARY_MODEL:-sonnet}"

force=false
only=""
while [ $# -gt 0 ]; do
  case "$1" in
    --force) force=true ;;
    --only) only="${2:?--only needs a version, e.g. --only 2026.9.3}"; shift ;;
    -h|--help) sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
  shift
done

for dependency in claude jq awk; do
  command -v "$dependency" >/dev/null 2>&1 || { echo "Missing dependency: $dependency" >&2; exit 1; }
done
[ -f "$CHANGELOG" ] || { echo "$CHANGELOG not found — run scripts/generate-changelog.sh first." >&2; exit 1; }

result='{}'
[ -f "$OUT" ] && result="$(cat "$OUT")"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Split the changelog into one file of raw notes per release, and record the version order.
awk -v dir="$work" '
  /^## / {
    header = substr($0, 4)
    sub(/ [^0-9.].*$/, "", header)   # "<version> — <date>" -> "<version>"; the version is digits and dots
    gsub(/^[ \t]+|[ \t]+$/, "", header)
    version = header
    print version >> (dir "/.order")
    next
  }
  version != "" { print >> (dir "/" version) }
' "$CHANGELOG"
[ -f "$work/.order" ] || { echo "No '## <version>' headings in $CHANGELOG." >&2; exit 1; }

new=0
while IFS= read -r version; do
  [ -n "$version" ] || continue
  [ -n "$only" ] && [ "$version" != "$only" ] && continue

  if [ "$force" != true ] && [ -z "$only" ] \
     && [ "$(jq -r --arg v "$version" 'has($v)' <<<"$result")" = "true" ]; then
    continue
  fi

  notes="$(cat "$work/$version" 2>/dev/null || true)"
  [ -n "${notes//[$'\n\t ']/}" ] || { echo "Skipping $version (no notes)." >&2; continue; }

  echo "Summarizing $version..." >&2
  prompt="Rewrite these release notes for the Kuulla podcast app as a short \"what's new\" blurb for the marketing site's release list.

Rules:
- One or two sentences. Plain and concrete, written for a listener, not a developer.
- Lead with what changed for the user. No version numbers, no dates, no bullet lists, no \"we\", no hype words (\"exciting\", \"powerful\", \"seamless\", \"revamped\").
- Fold internal-only work (CI, infra, tests, docs, refactors) in as a trailing \"plus behind-the-scenes fixes\" at most. If the release is entirely internal, output exactly: Behind-the-scenes improvements.
- Output only the blurb text, no preamble, no quotes.

Release notes:
$notes"

  # Don't let one failed `claude` call (rate limit, network) abort the whole run.
  raw=""
  if ! raw="$(printf '%s' "$prompt" | claude -p --model "$MODEL" 2>/dev/null)"; then
    echo "  claude failed for $version — leaving it out" >&2
    continue
  fi
  summary="$(printf '%s' "$raw" | tr -d '\r' | tr '\n' ' ' | sed -e 's/  */ /g' -e 's/^ *//' -e 's/ *$//')"
  if [ -z "$summary" ]; then
    echo "  no summary produced for $version — leaving it out" >&2
    continue
  fi

  result="$(jq --arg v "$version" --arg s "$summary" '.[$v] = $s' <<<"$result")"
  new=$((new + 1))
done < "$work/.order"

printf '%s\n' "$result" | jq --sort-keys '.' > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
echo "Wrote $OUT ($new updated)." >&2
