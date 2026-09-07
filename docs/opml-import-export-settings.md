# OPML import & export

> **Status (milestone #39):** shipped, but the API surface below is the pre-implementation
> sketch and no longer matches the code. What actually landed: `POST /api/subscriptions/import`
> and `GET /api/subscriptions/export` (not `/api/opml/*`), reached from the Subscriptions page /
> screen rather than a Settings section. Feeds are resolved by URL directly —
> `IShowService.GetOrCreateByFeedUrlAsync` fetches the feed for title/author/artwork and mints a
> `Show` with a deterministic id — so a podcast that isn't in Kuulla's directory still imports.
> Dedup skips feeds the user is already subscribed to. See the OPML entry in the README's
> Features list and the PRs under milestone #39 for the real behaviour.

Spec for [#189](https://github.com/sheridan-apps/kuulla/issues/189)'s "Import &
Export" settings section, decided against
[settings-architecture.md](./settings-architecture.md)'s IA, which places this as
its own standalone section (7) rather than folding it into another category.

## Research

- **Pocket Casts**: OPML import/export under Settings > Import/Export, the common
  migration path onto/off the app.
- **Overcast**: OPML import/export, same purpose — moving subscriptions to/from
  Apple Podcasts, Pocket Casts, etc.

## Existing state

Subscribing (`SubscriptionService.SubscribeAsync(userId, showId)`) always takes a
`showId` for a `Show` that already exists in the `shows` Cosmos container — it never
takes a raw feed URL. A `Show` gets into that container one of two ways today:
`ShowService.SearchAsync` caches every directory-search result it returns
(`IPodcastDirectoryClient.SearchAsync`, an external catalog search), or
`GetByIdAsync` enriches an already-cached `Show`'s `Description` from its feed
(`IPodcastFeedClient.FetchAsync`). Critically, `IPodcastFeedClient.FetchAsync`
returns `PodcastFeedContent(Description, Episodes)` only — no `Title`/`Author`/
`ArtworkUrl` — so fetching a feed directly, without a directory search result to
supply those fields, cannot build a complete `Show` record with what exists today.

## Decisions

### Import

- New endpoint `POST /api/opml/import`, accepting an uploaded OPML file. Parses
  every `<outline>` element's `xmlUrl` (feed URL) and `text`/`title` attributes —
  the two effectively-universal OPML podcast-outline attributes every exporting app
  (Pocket Casts, Overcast, Apple Podcasts) writes.
- For each entry's feed URL, in order:
  1. Look up a `Show` already cached in the `shows` container by exact `FeedUrl`
     match (a new query — `ShowService` has no by-feed-URL lookup today, only
     by-id and directory search).
  2. If not cached, fall back to `IPodcastDirectoryClient.SearchAsync` using the
     outline's title text, and match whichever result's `FeedUrl` equals the
     import entry's `xmlUrl` (this is the existing `SearchAsync` path, which
     already caches its results — no new caching logic needed here).
  3. If neither finds a match, the entry is **not imported** — this issue does not
     add feed-only show ingestion (parsing raw feed XML for `Title`/`Author`/
     `ArtworkUrl` bypassing the directory). `PodcastFeedContent` doesn't carry those
     fields, so building a complete `Show` from a feed URL alone needs extending
     `IPodcastFeedClient`/`PodcastFeedContent` first — a separate, real feature to
     scope on its own, not something to half-build as a side effect of this issue.
     A user whose imported podcast isn't in Kuulla's directory has to add it
     manually via search once it's indexed, same as any other not-yet-discovered
     show.
  4. Every matched show is subscribed via the existing
     `SubscriptionService.SubscribeAsync(userId, showId)` — one call per entry, the
     same call a manual subscribe makes, so back-catalog unlistened-limit
     enforcement and everything else `SubscribeAsync`'s callers already get keeps
     working unchanged. Re-importing an OPML file (or an entry the user already
     subscribes to) is a no-op: `SubscribeAsync` is already idempotent, returning
     the existing subscription on a Cosmos conflict rather than erroring.
- Duplicate feed URLs within the same OPML file are deduplicated before this
  per-entry pass runs, so a file with the same show listed under two folders
  doesn't do redundant lookups.
- Response is a **per-entry report** — imported / already subscribed / not
  found — not a single pass/fail for the whole file. Reporting nothing but "OPML
  imported" would leave a user with no way to tell which of, say, 40 podcasts
  actually came in versus silently didn't match Kuulla's directory.

### Export

- New endpoint `GET /api/opml/export`, returning a standard OPML document built
  from the signed-in user's existing subscriptions
  (`SubscriptionService.GetSubscriptionsAsync`). `Subscription` itself only carries
  `ShowTitle`/`ShowAuthor`/`ShowArtworkUrl` — no `FeedUrl` — so building each
  `<outline>`'s required `xmlUrl` needs one additional `ShowService.GetByIdAsync`
  per subscription's `ShowId` to fetch its `FeedUrl` (run concurrently, the same
  `Task.WhenAll(subscriptions.Select(...))` shape `SubscriptionService` already uses
  for its own per-show fan-out, e.g. `GetNewEpisodesAsync`). One `<outline
  type="rss" text="{ShowTitle}" xmlUrl="{FeedUrl}">` per subscription. Served as an
  attachment (`Content-Disposition: attachment; filename="kuulla-subscriptions.opml"`,
  `Content-Type: text/x-opml`), so a client only has to trigger a download, not
  parse or render anything.

### Validation & error handling

- A file that isn't well-formed XML, or has no `<outline>` elements with an
  `xmlUrl`, is rejected outright with a `400` and a clear message — no
  best-effort partial parse of a malformed file. This is a plain input-validation
  boundary (an uploaded file is external input), not a case to silently tolerate.
- Per-entry lookup failures (see "Import" step 3) are not validation errors — they
  land in the per-entry report as "not found," since the *file* was valid even
  though one show in it isn't in Kuulla's directory.

### Where this lives in the settings IA

- A standalone "Import & Export" section (per settings-architecture.md, not folded
  into Account & Privacy) — the issue's own "Decide" section asks this, and this
  spec's answer is standalone: OPML is a subscriptions-migration feature a user
  reaches for once, independent of account/privacy actions, and grouping it there
  would bury it under Account & Privacy's destructive actions instead of near where
  a user manages their subscriptions.

## Data model

No `UserSettings`/`ShowSettings` changes — import/export are one-shot actions
against existing `subscriptions`/`shows` data, not a persisted preference. No new
Cosmos container: import writes go through the existing `SubscribeAsync` path into
the existing `subscriptions` container, and any newly-discovered `Show`s get cached
into the existing `shows` container the same way a manual search does today.

## UI

- iOS `SettingsView.swift` / Web `Settings.razor`: an "Import & Export" section
  (position 7) with:
  - "Import Subscriptions (OPML)" row — opens a file picker (iOS: `.fileImporter`;
    Web: an `<InputFile>`), uploads to `POST /api/opml/import`, then shows the
    per-entry report (e.g. "32 imported, 3 already subscribed, 5 not found — add
    manually via search").
  - "Export Subscriptions (OPML)" row — downloads from `GET /api/opml/export`
    (iOS: `.fileExporter`/share sheet; Web: a plain anchor download).
- No per-show override entry point — nothing in this section is a per-show setting.
