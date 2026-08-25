# Siri Shortcuts & voice integration settings

Spec for [#191](https://github.com/sheridan-apps/kuulla/issues/191)'s "Siri &
Shortcuts" settings section, decided against
[settings-architecture.md](./settings-architecture.md)'s IA (iOS-only).

## Research

- **Pocket Casts**: Siri Shortcuts for "play latest episode," "play [podcast],"
  donated shortcuts a user can add their own voice phrase to.
- **Overcast**: Siri Shortcuts for play/pause/skip actions.

## Existing state

Fully greenfield — there's no Intents/`AppIntent`/`NSUserActivity` code anywhere in
the iOS target today. What already exists that intents can build on:
`AudioPlayer.shared` (`AudioPlayer.swift`) is a singleton reachable from anywhere in
the app process — App Intents (unlike a widget extension) run in the main app's
process, so an intent's `perform()` can call it directly, no shared-container
plumbing required. `EpisodeDetailView.resolvedPlaybackURL` already resolves a
downloaded-vs-streaming URL for an episode; an intent needs the same resolution,
currently private to that view. There is no persisted "currently playing episode"
concept — the closest existing proxy is `EpisodeStateRecord`'s
`positionSeconds`/`updatedAt`/`completed` fields, the same data
[#116](https://github.com/sheridan-apps/kuulla/issues/116) (Now Playing info &
remote command center) will need to restore playback state across a cold launch.

## Decisions

### Which intents to expose

- **Play Latest Episode** — plays the single newest unlistened episode across all
  subscriptions (the same "new episodes" ordering
  `SubscriptionService.GetNewEpisodesAsync` already produces for the app's own new-
  episodes list, not a separate ranking invented for this intent).
- **Resume Playback** — resumes whatever was last playing. Resolved the same way
  \#116 will need to resolve "what to restore on cold launch": the episode with the
  most recent `EpisodeStateRecord.updatedAt` where `completed == false`. This issue
  and #116 both need that same resolution logic — whichever lands first should own
  it as a shared helper, not a query each reimplements separately.
- **Play [Podcast]** — a per-show intent, donated once per subscribed show (see
  "Donation," below), that plays the latest unlistened episode of that specific
  show.
- **Skip Forward / Skip Back** — calls `AudioPlayer`'s existing skip amount (per
  [playback-settings.md](./playback-settings.md)'s new `SkipForwardSeconds`/
  `SkipBackSeconds` `UserSettings` fields) against whatever's currently playing;
  a no-op (not a crash) if nothing is currently playing.
- No pause/play-pause toggle intent — Siri's system-level media controls
  (`MPRemoteCommandCenter`, again #116) already cover pause/resume-in-place for
  whatever's actively playing once that's wired up; a Kuulla-specific intent for
  the same action would just be a second path to identical behavior.

### Donation

- **Play Latest Episode**, **Resume Playback**, **Skip Forward**, and **Skip
  Back** are donated once, at first launch (or first use), as static
  `AppShortcutsProvider`-declared shortcuts (the `AppShortcuts` API, iOS 16+) —
  always available in Shortcuts/Siri without the user having to have triggered the
  underlying action first, since these don't depend on per-show state.
- **Play [Podcast]** is donated per show at subscribe time and un-donated at
  unsubscribe. Donation is an on-device Intents-framework call, so it hooks the
  iOS client's existing `SubscriptionClient.subscribe(showId:)`/`unsubscribe(showId:)`
  call sites (`ShowDetailView`'s subscribe/unsubscribe action) — not
  `SubscriptionService.SubscribeAsync`, the API's own same-named server method,
  which has no access to on-device Intents/Shortcuts at all. Shortcuts has no use
  for "play a show you're not subscribed to," and leaving stale donations around
  after unsubscribing would surface dead shortcuts in the system Shortcuts app.

### Settings UI

- A single settings screen entry, not a per-intent toggle list: "Siri &
  Shortcuts" navigates to a screen showing which of the four static shortcuts
  exist plus a brief explanation, with each row deep-linking to the system
  `INUIAddVoiceShortcutViewController`/Shortcuts app flow for actually assigning a
  phrase. Kuulla doesn't need its own per-intent enable/disable switches: the
  `AppShortcuts` donations exist unconditionally (matching "Which shortcuts/intents
  to expose" above), and whether a phrase is actually *assigned* to one is state
  the system's own Shortcuts app already owns and displays — duplicating an
  enabled/disabled toggle in Kuulla's UI would just be a second, potentially
  stale view of what the OS already shows accurately.
- This directly answers the issue's own "any settings UI needed to manage/donate
  shortcuts vs system-level only" question: a system-level entry point, not a
  Kuulla-owned management surface.

## Data model

No `UserSettings`/`ShowSettings` changes — donated shortcuts and any phrase a user
assigns to one are OS-level state (`NSUserActivity`/`INVoiceShortcut` records
Siri owns), not something Kuulla stores or syncs. Device-local per
settings-architecture.md's [Sync scope](./settings-architecture.md#sync-scope) —
same treatment as Widgets: a donated Siri shortcut is a property of *this*
device's Siri/Shortcuts configuration, not a preference a second device could
receive and apply.

## UI

- iOS `SettingsView.swift` only (no Web equivalent — Siri has no Web analog,
  hidden entirely per settings-architecture.md): a "Siri & Shortcuts" row
  navigating to the informational screen described above.
- No per-show override entry point for the four static shortcuts (nothing to
  override); "Play [Podcast]"'s per-show donation happens automatically at
  subscribe/unsubscribe, not through a settings toggle a user manages.
