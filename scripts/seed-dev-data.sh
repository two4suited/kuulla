#!/usr/bin/env bash
# Subscribes the local dev user ("local-test-user") to 5 real, well-known podcasts, then seeds one
# Manual playlist ("Favorites") and one Dynamic playlist ("Daily Mix") from those shows, so a fresh
# `aspire run`/`aspire start` environment has real shows/episodes/playlists to develop against
# instead of an empty library (issue #246, #250).
#
# Reuses real data sources rather than faking anything: shows come from the same iTunes search
# (GET /api/shows/search) the app itself uses, episodes are read live from each show's real RSS
# feed, and playlists are created through the real /api/playlists endpoints (not the test-only
# /dev/seed-playlists hook). The only "test" piece is the auth token, minted via the
# Development/DEBUG-only, loopback-only /dev/test-token endpoint (see Program.cs) instead of a
# real Google sign-in.
#
# Invoked by AppHost.cs as an explicit-start executable resource ("seed-dev-data") — start it
# from the Aspire dashboard after `aspire run`/`aspire start` once the "api" resource is healthy.
# Idempotent: POST /api/subscriptions is create-or-return-existing (SubscriptionService), so
# running this more than once never creates duplicate subscriptions.
set -euo pipefail

for dependency in curl python3; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    echo "seed-dev-data.sh: '${dependency}' is required but not found on PATH" >&2
    exit 1
  fi
done

if [[ -z "${KUULLA_API_BASE_URL:-}" ]]; then
  echo "seed-dev-data.sh: KUULLA_API_BASE_URL is not set" >&2
  exit 1
fi

BASE_URL="${KUULLA_API_BASE_URL%/}"

# 5 real, actively-published, popular podcasts with reliable feeds — enough variety (news,
# science, culture) to be useful for exercising Library/Subscriptions/New Episodes locally.
PODCAST_QUERIES=(
  "Radiolab"
  "This American Life"
  "The Daily"
  "99% Invisible"
  "Planet Money"
)

echo "seed-dev-data.sh: waiting for API at ${BASE_URL} to become healthy..."
for _ in $(seq 1 60); do
  if curl -fsS -o /dev/null "${BASE_URL}/health"; then
    break
  fi
  sleep 2
done

if ! curl -fsS -o /dev/null "${BASE_URL}/health"; then
  echo "seed-dev-data.sh: API never became healthy at ${BASE_URL}" >&2
  exit 1
fi

echo "seed-dev-data.sh: minting local dev token..."
TOKEN=$(curl -fsS -X POST "${BASE_URL}/dev/test-token" | python3 -c "import json,sys; print(json.load(sys.stdin)['token'])")

if [[ -z "$TOKEN" ]]; then
  echo "seed-dev-data.sh: failed to mint a dev token" >&2
  exit 1
fi

seeded=0
show_ids=()
for query in "${PODCAST_QUERIES[@]}"; do
  echo "seed-dev-data.sh: searching for '${query}'..."
  # Prefer an exact (case-insensitive) title match over the top search hit — iTunes' ranking can
  # drift and put a similarly-named show, a rebroadcast, or an unrelated result first, which would
  # silently seed the wrong podcast. Falls back to the first result only if nothing matches exactly.
  show_id=$(curl -fsS -G "${BASE_URL}/api/shows/search" --data-urlencode "q=${query}" \
    | python3 -c "
import json, sys
query = sys.argv[1].strip().casefold()
results = json.load(sys.stdin)
exact = next((r for r in results if r.get('title', '').strip().casefold() == query), None)
chosen = exact or (results[0] if results else None)
print(chosen['id'] if chosen else '')
" "$query" 2>/dev/null) || show_id=""

  if [[ -z "$show_id" ]]; then
    echo "seed-dev-data.sh: WARNING no search result for '${query}', skipping" >&2
    continue
  fi

  if curl -fsS -X POST "${BASE_URL}/api/subscriptions" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"showId\": \"${show_id}\"}" \
    -o /dev/null; then
    echo "seed-dev-data.sh: subscribed to '${query}' (show ${show_id})"
    seeded=$((seeded + 1))
    show_ids+=("$show_id")
  else
    echo "seed-dev-data.sh: WARNING failed to subscribe to '${query}' (show ${show_id})" >&2
  fi
done

echo "seed-dev-data.sh: done — seeded ${seeded}/${#PODCAST_QUERIES[@]} podcasts for local-test-user."

# Also seed one Manual and one Dynamic playlist so a fresh environment exercises both playlist
# types, not just subscriptions. Uses the real /api/playlists endpoints (not the
# /dev/seed-playlists test-only hook) so this goes through the same code path a real client would,
# consistent with how the shows/episodes above come from real search + RSS rather than fakes.
if [[ "${#show_ids[@]}" -eq 0 ]]; then
  echo "seed-dev-data.sh: WARNING no shows were seeded, skipping playlist seeding" >&2
  exit 0
fi

# POST /api/playlists always mints a fresh id (PlaylistService.Create*PlaylistAsync), unlike
# POST /api/subscriptions which is create-or-return-existing — so look up by name first to keep
# re-running this script idempotent instead of piling up duplicate "Favorites"/"Daily Mix"
# playlists every time.
find_playlist_id_by_name() {
  local name="$1"
  curl -fsS "${BASE_URL}/api/playlists" -H "Authorization: Bearer ${TOKEN}" \
    | python3 -c "
import json, sys
name = sys.argv[1]
playlists = json.load(sys.stdin)
match = next((p for p in playlists if p.get('name') == name), None)
print(match['id'] if match else '')
" "$name" 2>/dev/null
}

echo "seed-dev-data.sh: fetching an episode from show ${show_ids[0]} to seed the manual playlist..."
episode_id=$(curl -fsS -G "${BASE_URL}/api/shows/${show_ids[0]}/episodes" --data-urlencode "pageSize=1" \
  | python3 -c "
import json, sys
page = json.load(sys.stdin)
items = page.get('items', [])
print(items[0]['id'] if items else '')
" 2>/dev/null) || episode_id=""

manual_playlist_id=$(find_playlist_id_by_name "Favorites") || manual_playlist_id=""
if [[ -n "$manual_playlist_id" ]]; then
  echo "seed-dev-data.sh: manual playlist 'Favorites' already exists (${manual_playlist_id})"
else
  # 'type': 0 is PlaylistType.Manual — sent numerically since the API has no
  # JsonStringEnumConverter registered (see the Dynamic payload note below).
  manual_playlist_id=$(curl -fsS -X POST "${BASE_URL}/api/playlists" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"name": "Favorites", "type": 0}' \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])") || manual_playlist_id=""

  if [[ -n "$manual_playlist_id" ]]; then
    echo "seed-dev-data.sh: created manual playlist 'Favorites' (${manual_playlist_id})"
  else
    echo "seed-dev-data.sh: WARNING failed to create manual playlist 'Favorites'" >&2
  fi
fi

if [[ -n "$manual_playlist_id" ]]; then
  if [[ -n "$episode_id" ]]; then
    # POST .../items is itself idempotent (PlaylistService.AddItemAsync dedupes by episodeId),
    # so this is safe to repeat even if 'Favorites' already had the episode.
    if curl -fsS -X POST "${BASE_URL}/api/playlists/${manual_playlist_id}/items" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{\"episodeId\": \"${episode_id}\", \"showId\": \"${show_ids[0]}\"}" \
      -o /dev/null; then
      echo "seed-dev-data.sh: added episode ${episode_id} to 'Favorites'"
    else
      echo "seed-dev-data.sh: WARNING failed to add episode to 'Favorites'" >&2
    fi
  else
    echo "seed-dev-data.sh: WARNING no episode found for show ${show_ids[0]}, 'Favorites' left empty" >&2
  fi
fi

dynamic_playlist_id=$(find_playlist_id_by_name "Daily Mix") || dynamic_playlist_id=""
if [[ -n "$dynamic_playlist_id" ]]; then
  echo "seed-dev-data.sh: dynamic playlist 'Daily Mix' already exists (${dynamic_playlist_id})"
else
  # Dynamic playlist config requires priorityList to contain exactly the same shows as showIds
  # (see ValidateDynamicPlaylistConfig in Program.cs) — reuse the same order for both.
  # 'type' is sent as the numeric enum value (PlaylistType.Dynamic == 1) rather than the string
  # name — the API has no JsonStringEnumConverter registered, so System.Text.Json only accepts
  # the underlying int here.
  show_ids_json=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1:]))" "${show_ids[@]}")
  dynamic_payload=$(python3 -c "
import json, sys
show_ids = json.loads(sys.argv[1])
payload = {
    'name': 'Daily Mix',
    'type': 1,
    'dynamicConfig': {
        'showIds': show_ids,
        'maxEpisodes': 20,
        'priorityList': show_ids,
    },
}
print(json.dumps(payload))
" "$show_ids_json")

  if curl -fsS -X POST "${BASE_URL}/api/playlists" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$dynamic_payload" \
    -o /dev/null; then
    echo "seed-dev-data.sh: created dynamic playlist 'Daily Mix' (${#show_ids[@]} shows)"
  else
    echo "seed-dev-data.sh: WARNING failed to create dynamic playlist 'Daily Mix'" >&2
  fi
fi
