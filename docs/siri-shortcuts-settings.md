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
- **Play [Podcast]** — a per-show intent, made discoverable per subscribed show
  (see "Making the intents discoverable," below), that plays the latest
  unlistened episode of that specific show.
- **Skip Forward / Skip Back** — calls `AudioPlayer`'s existing skip amount (per
  [playback-settings.md](./playback-settings.md)'s new `SkipForwardSeconds`/
  `SkipBackSeconds` `UserSettings` fields) against whatever's currently playing;
  a no-op (not a crash) if nothing is currently playing.
- No pause/play-pause toggle intent — Siri's system-level media controls
  (`MPRemoteCommandCenter`, again #116) already cover pause/resume-in-place for
  whatever's actively playing once that's wired up; a Kuulla-specific intent for
  the same action would just be a second path to identical behavior.

### Making the intents discoverable

- **Play Latest Episode**, **Resume Playback**, **Skip Forward**, and **Skip
  Back** don't depend on per-show state, so they're declared as static entries in
  an `AppShortcutsProvider`'s `appShortcuts` array (the App Intents framework,
  iOS 16+). That declaration is what makes them show up in Siri/Spotlight/the
  Shortcuts app — it's static metadata read from the app's own code, not a
  runtime "donate this" call a launch path needs to trigger.
- **Play [Podcast]** is different: it needs a specific show as a parameter,
  which a purely static `AppShortcuts` phrase can't supply (there's no fixed
  list of shows at compile time). This needs an `AppIntent` with a show
  parameter backed by an `AppEntity` representing subscribed shows, plus
  runtime signals (the App Intents framework's relevance/donation APIs) telling
  Siri "this particular show is one the user plays often," hooked into the iOS
  client's existing `SubscriptionClient.subscribe(showId:)`/`unsubscribe(showId:)`
  call sites (`ShowDetailView`'s subscribe/unsubscribe action) rather than
  `SubscriptionService.SubscribeAsync`, the API's own same-named server method,
  which has no access to on-device Intents/Shortcuts at all. The exact
  relevance/donation API surface is an implementation detail for whichever issue
  builds this intent to work out against current App Intents documentation, not
  something this settings-catalog spec needs to pin down precisely; the
  decision this spec is making is that a subscribed show's entity should stop
  being offered once the user unsubscribes, mirroring "Shortcuts has no use for
  playing a show you're not subscribed to."

### Settings UI

- A single settings screen entry, not a per-intent toggle list: "Siri &
  Shortcuts" navigates to a screen listing the four static shortcuts plus a
  brief explanation, with a link out to the system's own Shortcuts/Siri phrase
  -assignment flow for actually assigning a voice phrase (the specific system UI
  for this is an iOS-version-dependent implementation detail, not something this
  spec needs to name). Kuulla doesn't need its own per-intent enable/disable
  switches: the four intents are unconditionally declared (matching "Which
  intents to expose" above), and whether a phrase is actually *assigned* to one
  is state the system's own Shortcuts app already owns and displays — duplicating
  an enabled/disabled toggle in Kuulla's UI would just be a second, potentially
  stale view of what the OS already shows accurately.
- This directly answers the issue's own "any settings UI needed to manage/donate
  shortcuts vs system-level only" question: a system-level entry point, not a
  Kuulla-owned management surface.

## Data model

No `UserSettings`/`ShowSettings` changes — declared shortcuts and any phrase a user
assigns to one are OS-level state that Siri/Shortcuts itself owns, not something
Kuulla stores or syncs. Device-local per settings-architecture.md's
[Sync scope](./settings-architecture.md#sync-scope) — same treatment as Widgets: an
assigned Siri phrase is a property of *this* device's Siri/Shortcuts configuration,
not a preference a second device could receive and apply.

## UI

- iOS `SettingsView.swift` only (no Web equivalent — Siri has no Web analog,
  hidden entirely per settings-architecture.md): a "Siri & Shortcuts" row
  navigating to the informational screen described above.
- No per-show override entry point for the four static shortcuts (nothing to
  override); "Play [Podcast]" becoming discoverable per show happens
  automatically at subscribe/unsubscribe, not through a settings toggle a user
  manages.
