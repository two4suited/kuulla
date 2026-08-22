# Downloads & storage settings

Spec for [#185](https://github.com/sheridan-apps/kuulla/issues/185)'s "Downloads &
Storage" settings section, decided against
[settings-architecture.md](./settings-architecture.md)'s IA and against the
[Offline Downloads](https://github.com/sheridan-apps/kuulla/milestone/28) milestone's
download manager ([#174](https://github.com/sheridan-apps/kuulla/issues/174)–
[#180](https://github.com/sheridan-apps/kuulla/issues/180)). This doc decides *what*
gets downloaded and kept; see
[data-usage-network-settings.md](./data-usage-network-settings.md) (#186) for *over
what connection*.

## Research

- **Pocket Casts**: per-podcast auto-download (with a global default), a storage cap
  that auto-evicts the oldest downloads once exceeded, a "delete after played" toggle,
  and a storage-used display with a manual clear action.
- **Overcast**: auto-download on/off per podcast, "delete played episodes
  automatically" with a configurable delay (immediately / after N hours), and a
  storage-used display.

## Decisions

### Auto-download rules

- **Global default**: `AutoDownloadNewEpisodes: bool`, default `false`. Off by
  default because auto-downloading is a bandwidth/storage commitment a user should
  opt into, not one made on their behalf the first time they add a show — consistent
  with `AutoArchiveRule.Never` and `PlaybackSpeed: 1.0f`'s "unmodified until the user
  opts in" convention in `UserSettings`.
- **Per-show override**: `AutoDownloadNewEpisodes: bool?` on `ShowSettings`, `null`
  meaning "inherit the global default" — the same nullable-override pattern
  `UnlistenedEpisodeCount` already uses. A user who wants every episode of one show
  kept offline (e.g. a slow-to-publish show they don't want to miss) without turning
  it on globally sets the override to `true`; one they don't want auto-downloaded
  despite a global default of `true` sets it to `false`.
- New episodes are detected the same way the existing feed-refresh path already
  detects them (no new detection mechanism); when auto-download resolves to `true`
  for a show, the new episode is handed to `DownloadManager.startDownload` (#175) the
  same as a manual tap would, so it goes through the same Wi-Fi-only gating (#180)
  and background-session machinery.

### Auto-delete rules

- `AutoDeleteRule` enum: `Never | AfterPlayed | AfterDays`.
  - `Never` (default) — a user must delete manually from the downloads list (#178) or
    an episode row (#176). Kept as the default for the same reason
    `AutoArchiveRule.Never` is: silently deleting a file a user downloaded on purpose
    is a surprising, hard-to-undo action to take without opt-in.
  - `AfterPlayed` — delete on the same completion signal #179 already hooks
    (`AudioPlayer.onDidFinishPlaying` / manual mark-played), excluding auto-played
    episodes per #179's own carve-out so a #100 "Restore" doesn't point at a deleted
    file.
  - `AfterDays: int` — delete `AfterDaysValue` days after `downloadedAt`
    (`DownloadedEpisodeRecord`, #174), independent of played state. This is a
    calendar-time rule, not a played-state rule, so it needs its own field
    (`AfterDaysValue: int`, default `7` when the rule is selected) rather than reusing
    `AutoArchiveRule`'s `afterDays`, which fires on archiving (hiding from lists), a
    different action from deleting a local file.
  - No storage-cap-eviction rule for this milestone (Pocket Casts' "auto-evict
    oldest") — it adds a background eviction policy (what counts as "oldest": least
    recently downloaded vs. least recently played) that isn't needed to ship offline
    downloads, and can be layered on later as its own field without reshaping this
    enum. `#186`'s connection-based rules are a separate concern and don't block on
    this decision either.
- Global-only (`UserSettings.DownloadsAndStorage.AutoDeleteRule`) — no per-show
  override. Unlike auto-download, which show gets kept offline, a per-show delete
  policy fragmentation ("some shows auto-delete after play, others never do") adds a
  second axis of state a user has to track in the downloads list (#178) for little
  benefit; a show that needs different handling is better served by the user managing
  it manually from that show's downloads.

### Storage usage & manual clear

- Handled entirely by #178 (Downloads management screen) reading
  `DownloadedEpisodeRecord.fileSizeBytes` directly — no separate `storageCapMb`
  setting or duplicate total in this settings section. Settings only needs a link
  into the #178 screen ("Manage Downloads →"), not its own storage display, so the
  byte total has exactly one source of truth instead of two views that could drift.

## Data model

Extends `UserSettings`/`ShowSettings` (`Kuulla.Api.Models`) per
settings-architecture.md's shape — not a new document:

```
UserSettings                       (id = userId)
├─ downloadsAndStorage
│  ├─ autoDownloadNewEpisodes : bool = false
│  ├─ autoDeleteRule : Never|AfterPlayed|AfterDays = Never
│  ├─ autoDeleteAfterDays : int = 7          // only meaningful when autoDeleteRule == AfterDays

ShowSettings   (id = ShowSettings.BuildId(userId, showId))
├─ autoDownloadNewEpisodes : bool?           // null = inherit UserSettings default
```

Synced like every other field in `UserSettings`/`ShowSettings` (per
settings-architecture.md's [Sync scope](./settings-architecture.md#sync-scope)) —
"which shows auto-download and when downloads get cleaned up" is a per-user
preference, not a per-device one, unlike #186's connection-based settings.

## UI

- iOS `SettingsView.swift` / Web `Settings.razor`: a "Downloads & Storage" section
  (per settings-architecture.md's ordering, position 4) with:
  - "Auto-download new episodes" toggle (global default).
  - "Delete downloads" picker: Never / After played / After N days (N editable inline
    when "After N days" is selected).
  - "Manage Downloads" row navigating to #178's screen.
- Per-show override: a "Podcast settings" entry on the show page (existing
  `ShowSettingsSheet`/Web equivalent per settings-architecture.md) gains an
  "Auto-download new episodes" toggle with the same "Using default" / "Reset to
  default" behavior every other per-show override field already has.

## Interaction with the Offline Downloads download manager

- `DownloadManager` (#175) is the only thing that actually starts/cancels file
  transfers; this settings section only decides *when* it's told to (auto-download
  resolution) and *when a completed download gets removed* (auto-delete rule) — it
  doesn't duplicate any of #175's transfer/progress logic.
- Auto-delete's `AfterPlayed` case shares its trigger point with #179 exactly; #179
  should read `AutoDeleteRule` (defaulting its "Delete downloads after playing"
  toggle to `AutoDeleteRule == AfterPlayed` conceptually, or fold into this same enum
  during #179's implementation rather than keeping two separate toggles for the same
  outcome — left as an implementation note for #179, not a decision this issue needs
  to force ahead of time).
- Wi-Fi gating for anything this section triggers (auto-download in particular) is
  #186's concern, not this doc's.
