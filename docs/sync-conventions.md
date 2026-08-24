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
client and server exchange changes using this metadata) was designed once, in #33,
and extracted into reusable infrastructure in #84 — see below.

## Adopted so far

- `EpisodeState` (`src/Kuulla.Api/Models/EpisodeState.cs`) — the reference
  implementation of this convention and the reconciliation protocol below, built
  for #32/#33 and rebased onto the generic framework (#84). Summary cached at
  `sync:episodes:{userId}`.
- `User` (`src/Kuulla.Api/Models/User.cs`) — retrofitted with `updatedAt`/`deviceId`
  ahead of any user-profile sync work, so it won't need a migration later. No sync
  behavior exists for `User` yet.
- `UserSettings` (`src/Kuulla.Api/Models/UserSettings.cs`) — #40/#41's settings sync,
  the first single-record-per-user domain (as opposed to a per-user collection like
  episodes/playlists): `queryAllAsync` returns a 0-or-1-item list and `changes` is
  capped at one entry per sync call. Summary cached at `sync:settings:{userId}`.
  `ShowSettings` (per-show overrides, same container) has `updatedAt`/`deviceId`
  stamped on every write but isn't wired into the reconciler yet — only the global
  `UserSettings` document syncs across devices so far.

## Reconciliation framework (`Kuulla.Api.Services.Sync`, #84)

The always-push/always-return-delta protocol below is implemented once as generic
infrastructure, so a new domain wires up an adapter instead of re-deriving the merge
and delta logic:

- **`ISyncableRecord`** — the interface a domain's stored record must implement
  (`Id`, `UpdatedAt`). Point this at whatever the record's server-stamped id/
  timestamp fields are.
- **`SyncSummaryCache<T>`** (`SyncSummaryCache.cs`) — wraps the
  `sync:{domain}:{userId}` → `{ hash, updatedAt }` Redis cache described above.
  Construct one per domain with `new SyncSummaryCache<TRecord>(redis, "domain-name")`.
  `Compute()` is the shared hash algorithm (SHA-256 over sorted
  `"{recordId}:{updatedAt}"` pairs); `GetOrComputeAsync()` is cache-or-recompute for
  the fast path.
- **`SyncReconciler<TState, TChange>`** (`SyncReconciler.cs`) — the merge routine.
  Given a `SyncSummaryCache<TState>` and, per call, delegates for reading/upserting/
  querying-all a user's records plus how to read an incoming change's id/updatedAt
  and turn it into an accepted `TState`, `ReconcileAsync` runs the full protocol:

  1. Fast path: if `changes` is empty and `localHash` matches the cached/computed
     summary hash, return `serverChanges: []` without touching storage.
  2. For each incoming change, apply last-write-wins: accept it (via
     `buildAcceptedState`, which should stamp `updatedAt`/`deviceId` server-side)
     only if its `updatedAt` is newer than the stored record's; otherwise the stored
     record wins and the client's write is discarded.
  3. Compute the delta: every record with `updatedAt > lastSyncedAt` that the client
     doesn't already hold the winning version of (excluding what step 2 just
     accepted from that client).
  4. Recompute and cache the new summary, and return
     `{ ServerChanges, SyncedAt, Hash }`.

A new domain (e.g. #41 settings sync) implements this by:

1. Making its stored record implement `ISyncableRecord`.
2. Constructing `new SyncSummaryCache<TRecord>(redis, "domain-name")` and
   `new SyncReconciler<TRecord, TChange>(summaryCache)`.
3. Calling `ReconcileAsync` from its own sync endpoint/service method, supplying the
   read/upsert/query-all delegates for its own storage (Cosmos container, partition
   key, etc.) and a domain-specific request/result DTO shape at the API boundary if
   desired (see `SyncEpisodesRequest`/`SyncEpisodesResult` for the pattern — thin
   wrappers around the generic `SyncReconciliationResult<T>`).

See `EpisodeStateService` (`src/Kuulla.Api/Services/EpisodeStateService.cs`) for the
reference adapter other domains should mirror.

## Web change-detection pattern (`Kuulla.Web.Services.Sync`/`Components.Sync`, #86)

The Blazor side of "did something change elsewhere, show an indicator, reconcile"
is also generic infrastructure rather than something each page hand-rolls:

- **`SyncStatusService<TState>`** (`Services/Sync/SyncStatusService.cs`) — wraps a
  domain's poll call (its sync endpoint hit with an empty change set, e.g.
  `POST /api/sync/episodes` with `changes: []`) and tracks `IsSyncing`/
  `HasRemoteUpdate`. `CheckNowAsync()` polls; a check already in flight is not
  duplicated. When the poll returns a changed hash *and* a non-empty
  `ServerChanges`, the domain's `applyServerChanges` callback merges them into local
  view-model state (optimistic local update + server reconciliation on conflict,
  last-write-wins per the reconciliation framework above) and `HasRemoteUpdate` is
  set. `SyncLocalState(hash, syncedAt)` lets the domain tell the service about a
  local push it made outside this service, so the next poll doesn't mistake the
  user's own write for a remote one.
- **`SyncStatusIndicator.razor`** (`Components/Sync/SyncStatusIndicator.razor`) — the
  "syncing…" / "updated from another device" indicator. Binds to the non-generic
  `ISyncStatusService` surface (so the component itself isn't generic), and drives
  poll-on-focus via the collocated `Components/Sync/SyncStatusIndicator.razor.js`, which calls back into .NET on
  `focus`/`visibilitychange`.

A new page (e.g. #34 episode sync UI, #42 settings sync UI) consumes this by
constructing a `SyncStatusService<TState>` (scoped to the page/component, with its
own poll/apply delegates for its domain) and dropping `<SyncStatusIndicator Service="..."/>`
into the page — instead of writing its own focus listener and conflict banner.
Requires `@rendermode InteractiveServer` (or `InteractiveServerRenderMode`) on the
host page, since the indicator uses JS interop.
