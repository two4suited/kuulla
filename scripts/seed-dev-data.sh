#!/usr/bin/env bash
# Subscribes the local dev user ("local-test-user") to 5 real, well-known podcasts so a fresh
# `aspire run`/`aspire start` environment has real shows/episodes to develop against instead of
# an empty library (issue #246).
#
# Reuses real data sources rather than faking anything: shows come from the same iTunes search
# (GET /api/shows/search) the app itself uses, and episodes are read live from each show's real
# RSS feed. The only "test" piece is the auth token, minted via the Development/DEBUG-only,
# loopback-only /dev/test-token endpoint (see Program.cs) instead of a real Google sign-in.
#
# Invoked by AppHost.cs as an explicit-start executable resource ("seed-dev-data") — start it
# from the Aspire dashboard after `aspire run`/`aspire start` once the "api" resource is healthy.
# Idempotent: POST /api/subscriptions is create-or-return-existing (SubscriptionService), so
# running this more than once never creates duplicate subscriptions.
set -euo pipefail

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
for query in "${PODCAST_QUERIES[@]}"; do
  echo "seed-dev-data.sh: searching for '${query}'..."
  show_id=$(curl -fsS -G "${BASE_URL}/api/shows/search" --data-urlencode "q=${query}" \
    | python3 -c "
import json, sys
results = json.load(sys.stdin)
print(results[0]['id'] if results else '')
" 2>/dev/null) || show_id=""

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
  else
    echo "seed-dev-data.sh: WARNING failed to subscribe to '${query}' (show ${show_id})" >&2
  fi
done

echo "seed-dev-data.sh: done — seeded ${seeded}/${#PODCAST_QUERIES[@]} podcasts for local-test-user."
