# Sync metadata conventions

This is the shared shape for any container/collection that needs cross-device sync
(last-write-wins conflict resolution, cheap "has anything changed" checks). It was
designed in [#32](https://github.com/two4suited/kuulla/issues/32) for episode
sync state and is meant to be reused rather than re-derived per domain — see
[#33](https://github.com/two4suited/kuulla/issues/33) (episode sync API) and
[#41](https://github.com/two4suited/kuulla/issues/41) (settings sync) as the
first consumers.

## Per-document fields

Every syncable document gets two fields in addition to its own data:

- **`updatedAt`** (ISO 8601 timestamp) — set by the server on every write, never by
  the client. Drives last-write-wins: an incoming write is accepted only if its
  `updatedAt` is newer than the stored record's.
- **`deviceId`** — the origin of the last write. Not used for conflict resolution,
  only for debugging/telemetry (e.g. "why did my phone's edit get discarded").

## Per-user collection summary

Every syncable collection gets a summary cached in Redis, keyed
`sync:{domain}:{userId}`:

```
{ "hash": "<sha256>", "updatedAt": "<max updatedAt in the collection>" }
```

- **`hash`** — SHA-256 over the sorted set of `"{recordId}:{updatedAt}"` pairs for
  that user's records in the collection. Lets a client compare its last-known hash
  against the server's in one round trip instead of pulling every record.
- **`updatedAt`** — the max `updatedAt` across the user's records in the collection.
- Invalidated and recomputed on write. Cost is per-user, not global — a write by one
  user never touches another user's cached summary.

## Adding a new syncable container

1. Add `updatedAt` (server-set, every write) and `deviceId` to the document shape.
2. Set `updatedAt` on create and on every subsequent write; never trust a
   client-supplied value for it.
3. If/when the container needs a sync endpoint, cache its per-user summary at
   `sync:{domain}:{userId}` using the hash/updatedAt shape above rather than
   inventing a new one.

This doc only covers the shape of the metadata. The reconciliation protocol (how a
client and server exchange changes using this metadata) is designed once, in #33,
and other domains should reuse it rather than re-implement their own handshake.

## Adopted so far

- `EpisodeState` (`src/Kuulla.Api/Models/EpisodeState.cs`) — the reference
  implementation of this convention and the reconciliation protocol below, built
  for #32/#33. Summary cached at `sync:episodes:{userId}`.
- `User` (`src/Kuulla.Api/Models/User.cs`) — retrofitted with `updatedAt`/`deviceId`
  ahead of any user-profile sync work, so it won't need a migration later. No sync
  behavior exists for `User` yet.

## Reconciliation protocol (`POST /api/sync/episodes`)

One round trip, given `{ deviceId, lastSyncedAt, localHash, changes }`:

1. For each incoming record in `changes`, apply last-write-wins: accept it (upsert,
   server re-stamps `updatedAt`/`deviceId`) only if its `updatedAt` is newer than the
   stored record's; otherwise the stored record wins and the client's write is
   discarded.
2. Compute the delta: every record with `updatedAt > lastSyncedAt` that the client
   doesn't already hold the winning version of (i.e. excluding what step 1 just
   accepted from that client).
3. Return `{ serverChanges, syncedAt: now, hash: newHash }` using the sync-summary
   cache above.

Fast path: if `changes` is empty and `localHash` matches the freshly computed hash,
skip the reconciliation query entirely and return `serverChanges: []`.

See `EpisodeStateService` (`src/Kuulla.Api/Services/EpisodeStateService.cs`) for the
implementation other domains (e.g. #41 settings sync) should mirror.
