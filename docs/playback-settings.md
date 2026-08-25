# Playback settings

Spec for [#182](https://github.com/sheridan-apps/kuulla/issues/182)'s "Playback"
settings section, decided against
[settings-architecture.md](./settings-architecture.md)'s IA (section 1, the
most-frequently-touched category). Covers the fields `UserSettings` doesn't already
have — skip interval, auto-play-next, resume behavior — and clarifies how the
existing `PlaybackSpeed`/`SmartSpeed`/`AutoSkipIntroSeconds`/`AutoSkipOutroSeconds`
fields (`Kuulla.Api.Models.UserSettings`) fit into this section rather than
introducing parallel ones.

## Research

- **Pocket Casts**: a global skip-forward/skip-back interval (several preset
  durations, e.g. 10/15/30/45s), "Auto Play" to continue into the next episode in Up
  Next when one finishes, and per-podcast intro/outro auto-skip.
- **Overcast**: global default playback speed and Voice Boost/Smart Speed, with a
  per-podcast override; "Smart Resume" to skip back a few seconds when resuming a
  paused episode.

## Decisions

### Skip forward/back interval

- New fields: `UserSettings.SkipForwardSeconds` / `SkipBackSeconds`, `int`, default
  `30` / `15` — matching the values already hard-coded into the iOS player's skip
  buttons today, so shipping this setting changes nothing for a user who never opens
  it.
- Global only, no per-show override. Unlike `AutoSkipIntroSeconds`/`AutoSkipOutroSeconds`
  (which vary by how long a specific show's intro actually is), the skip-button
  interval is a personal scrubbing preference independent of what's playing — Pocket
  Casts and Overcast both keep it global-only for the same reason.
- Distinct from `AutoSkipIntroSeconds`/`AutoSkipOutroSeconds`: those fire
  automatically at the start/end of an episode without a tap; this is the interval
  the existing manual skip-forward/skip-back buttons move by. Same document, same
  section, different fields — no naming collision since one is `AutoSkip*` and the
  other is `Skip*Seconds`.

### Auto-play next episode

- New field: `UserSettings.AutoPlayNext`, `bool`, default `true`. Unlike the other
  opt-in-by-default fields in `UserSettings` (`AutoArchiveRule.Never`,
  `AutoDownloadNewEpisodes: false`, `SmartSpeed: false`), continuing playback is the
  behavior a user already expects from a podcast app mid-queue — closer to
  `NotificationsEnabled: true`'s "the feature already implies the user wants this"
  reasoning than to a silent side effect like auto-archiving or auto-downloading.
- Global only, no per-show override — Up Next is a cross-show queue (per
  [#100](https://github.com/sheridan-apps/kuulla/issues/100) and the auto-played
  "Restore" affordance `EpisodeDetailView.restoreAutoPlayed` already references), so
  "continue to the next queued episode" isn't a property of any single show to
  override per-show.
- When `false`, playback stops at the end of the current episode instead of
  advancing to the next Up Next entry; this only changes whether the *next* episode
  starts automatically; the existing `#179` auto-delete-after-played /
  `AutoArchiveRule` completion signal still fires the same way either way, since
  those trigger on "this episode finished," not on "the next one started."

### Resume behavior

- New field: `UserSettings.ResumeBehavior` enum: `Exact | SkipBackFewSeconds`,
  default `SkipBackFewSeconds`. Mirrors Overcast's "Smart Resume": resuming a
  paused/backgrounded episode rewinds a small fixed amount (5 seconds) before
  continuing playback, so a listener who paused mid-word doesn't lose the last
  syllable. `Exact` resumes at the precise saved position, for a listener who finds
  the rewind disorienting.
- The fixed 5-second rewind is not itself configurable (no `resumeSkipBackSeconds`
  field) — Overcast doesn't expose a duration for this either; it's a small
  fixed nudge, not a tunable interval like skip-forward/back, and adding a second
  configurable duration next to `SkipBackSeconds` would invite confusing the two.
- Applies wherever playback position is restored from a saved position: app
  relaunch, switching episodes and back, and (per the
  [Cross-Device Playback Handoff](https://github.com/sheridan-apps/kuulla/milestone/27)
  milestone) resuming a position synced from another device — this setting decides
  the resume behavior, not where the saved position came from.
- Global only, no per-show override — the "lost the last syllable" problem this
  solves isn't specific to any show.

### Speed / silence-trim / volume-boost as global defaults

- `PlaybackSpeed` and `SmartSpeed` (`UserSettings`) already are the global defaults
  this section surfaces; this issue doesn't change their shape, only confirms they
  live in the Playback settings section (not a separate one) and that their existing
  per-show override fields on `ShowSettings` (`PlaybackSpeed?`, `SmartSpeed?`,
  `null` = inherit) are exposed from the same "Podcast settings" sheet entry point
  settings-architecture.md already specifies — no new UI pattern needed here.
- "Volume boost" in the milestone's research notes refers to the same feature as
  `SmartSpeed` (silence trimming + volume normalization, per
  `SmartSpeedProcessor.swift`) — not a separate field. No new `VolumeBoost` setting.

## Data model

Extends `UserSettings` (`Kuulla.Api.Models`) — no new document, no changes to
`ShowSettings` beyond what already exists:

```
UserSettings                       (id = userId)
├─ skipForwardSeconds : int = 30    // new
├─ skipBackSeconds : int = 15       // new
├─ autoPlayNext : bool = true       // new
├─ resumeBehavior : Exact|SkipBackFewSeconds = SkipBackFewSeconds  // new
├─ playbackSpeed : float = 1.0      // existing, this section now owns its UI
├─ smartSpeed : bool = false        // existing, this section now owns its UI
├─ autoSkipIntroSeconds / autoSkipOutroSeconds : int = 0            // existing

ShowSettings   (id = ShowSettings.BuildId(userId, showId))
├─ playbackSpeed / smartSpeed / autoSkipIntroSeconds / autoSkipOutroSeconds : ...?  // existing, unchanged
                                    // (no per-show override for skipForward/BackSeconds,
                                    //  autoPlayNext, or resumeBehavior — see "Decisions" above)
```

Synced like every other `UserSettings` field, per settings-architecture.md's
[Sync scope](./settings-architecture.md#sync-scope) — none of the new fields are
device-local.

## UI

- iOS `SettingsView.swift` / Web `Settings.razor`: a "Playback" section (position 1)
  containing, in this order:
  - "Skip forward" / "Skip back" pickers (preset options, e.g. 10/15/30/45s),
    replacing the two buttons' currently-hardcoded intervals.
  - "Auto-play next episode" toggle.
  - "Resume position" picker: "Exactly where I left off" / "Skip back a few seconds"
    (`ResumeBehavior`).
  - "Playback speed" and "Smart Speed" controls — moved here from wherever they
    currently render (already `UserSettings` fields, this section is just their new
    home per the settings-architecture.md IA).
  - The existing "Auto-skip intro" / "Auto-skip outro" pickers (`SettingsView.swift`
    lines 74–81) stay in this section, unchanged.
- Per-show override: no change to `ShowSettingsSheet`/Web equivalent beyond what it
  already exposes for `PlaybackSpeed`/`SmartSpeed`/auto-skip — the three new fields
  in this issue have no per-show override to add there.
