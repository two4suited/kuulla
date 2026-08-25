# Settings architecture & IA

Designed in [#181](https://github.com/sheridan-apps/kuulla/issues/181) to give the
"App Settings" milestone a shared shape to build against before its per-category
issues ([#182](https://github.com/sheridan-apps/kuulla/issues/182)–
[#192](https://github.com/sheridan-apps/kuulla/issues/192)) land their own specs.
This doc covers navigation/IA, where per-podcast overrides live, sync scope, and the
settings data model — not the individual field-level decisions, which stay owned by
each category issue.

## Sections & order

One flat, single-scrolling settings list (Overcast-style) rather than Pocket Casts'
deeper nested groups — the milestone's category count is modest enough that a second
navigation level would add a tap without adding clarity. Order follows how often a
setting is touched after initial setup (most-used first):

1. **Playback** ([#182](https://github.com/sheridan-apps/kuulla/issues/182)) — skip
   intervals, auto-play, resume behavior, speed/silence-trim/volume-boost *global
   defaults*. Spec: [playback-settings.md](./playback-settings.md).
2. **Appearance** ([#183](https://github.com/sheridan-apps/kuulla/issues/183)) —
   theme, app icon, text size. Spec: [appearance-settings.md](./appearance-settings.md).
3. **Notifications** ([#184](https://github.com/sheridan-apps/kuulla/issues/184)) —
   global/per-podcast new-episode toggle, download-complete alerts; the API/DB fields
   this needs are tracked separately in
   [#214](https://github.com/sheridan-apps/kuulla/issues/214).
4. **Downloads & Storage** ([#185](https://github.com/sheridan-apps/kuulla/issues/185))
   — auto-download rules, auto-delete rules, storage usage/clear-downloads. Spec:
   [downloads-storage-settings.md](./downloads-storage-settings.md).
5. **Auto-Archive & Played Rules** ([#187](https://github.com/sheridan-apps/kuulla/issues/187))
   — global/per-podcast archive rule; placed right after Downloads & Storage since
   archive rules can trigger download deletion (#187's own "Decide" notes this
   overlap).
6. **Data Usage & Network** ([#186](https://github.com/sheridan-apps/kuulla/issues/186))
   — Wi-Fi-only streaming/downloading toggles (no bandwidth/quality tradeoff setting
   — see the spec's rationale). Kept distinct from Downloads & Storage: that section
   decides *what* to download/keep, this one decides *over what connection*. Spec:
   [data-usage-network-settings.md](./data-usage-network-settings.md).
7. **Import & Export** ([#189](https://github.com/sheridan-apps/kuulla/issues/189))
   — OPML. Spec: [opml-import-export-settings.md](./opml-import-export-settings.md).
8. **Widgets** ([#190](https://github.com/sheridan-apps/kuulla/issues/190)) —
   iOS-only; hidden entirely on Web (see [Web vs iOS parity](#web-vs-ios-parity)).
   Spec: [widgets-settings.md](./widgets-settings.md).
9. **Siri & Shortcuts** ([#191](https://github.com/sheridan-apps/kuulla/issues/191))
   — iOS-only.
10. **Accessibility** ([#192](https://github.com/sheridan-apps/kuulla/issues/192)) — Spec: [accessibility-settings.md](./accessibility-settings.md).
11. **Account & Privacy** ([#188](https://github.com/sheridan-apps/kuulla/issues/188))
    — deliberately last: destructive/high-stakes actions (sign out, delete account)
    shouldn't sit next to routine toggles. Spec: [account-privacy-settings.md](./account-privacy-settings.md).

Existing `UnlistenedEpisodeCount` (`SettingsView`/`Settings.razor` today) moves under
**Playback** as an "episode list" subsection — it's a per-show-overridable display
default, the same shape the Playback section already needs for speed/silence-trim.

## Per-podcast overrides vs global defaults

The existing `UserSettings`/`ShowSettings` split (`Kuulla.Api.Models`) is the pattern
every overridable field should follow, not something new: a global default lives on
`UserSettings`, and a per-show override lives on `ShowSettings` as the same field made
nullable, where `null` means "inherit the global default." `UnlistenedEpisodeCount`
already works this way today; playback speed, silence trimming, and volume boost
(tracked in #182 and their own per-feature milestones) are the next fields expected to
need it.

Entry points to the per-show override, both leading to the same show-settings
surface (`ShowSettingsSheet`/an equivalent Web modal):

- **From the global settings screen**: no per-show editing here — global settings
  only ever show/set the default. Per-show state isn't visible from this screen at
  all, so there's nothing here to get out of sync with a podcast's overrides.
- **From the show page**: a "Podcast settings" entry opens the same sheet, seeded
  with that show's current overrides (or "Using default" where unset), with a
  "Reset to default" action per field that clears the override (sets it back to
  `null`) rather than copying the current global value in.

## Sync scope

Every field on `UserSettings` is a synced, per-user default — that's the whole point
of the document (see [#41](https://github.com/sheridan-apps/kuulla/issues/41)/
[#42](https://github.com/sheridan-apps/kuulla/issues/42)/
[#43](https://github.com/sheridan-apps/kuulla/issues/43) settings-sync work). Two
categories are the exception, and are device-local (no `UserSettings` field, no sync
endpoint involvement):

- **Data Usage & Network** (#186) — Wi-Fi-only streaming/downloads is inherently
  about *this* device's connection, not the user's.
- **Notifications** (#184) — OS-level permission state and per-device delivery (push
  token registration, per #212) rather than a synced preference; the *"which event
  types notify me"* global/per-podcast toggles #184 decides on are still synced
  `UserSettings`/`ShowSettings` fields, distinct from the OS permission itself.

Widgets (#190) and Siri & Shortcuts (#191) are also device-local, for the same
reason as Data Usage & Network: a home-screen widget's layout and an OS's donated
Siri shortcuts are both properties of *this* device/OS install, not something a
second device could receive and apply. Neither has a `UserSettings` field in the
data model below, the same way Data Usage & Network doesn't.

Appearance (#183) is a partial exception rather than fully synced like the
sections below it: its app icon is iOS-only and device-local for the same
"can't sync a home-screen icon between devices" reason as Widgets/Siri &
Shortcuts (no `UserSettings` field), and text size has no field at all — Kuulla
relies on the OS's own Dynamic Type setting rather than storing one. Only
Appearance's theme is a synced `UserSettings` field, and even that field is
nullable rather than plainly defaulted — see
[appearance-settings.md](./appearance-settings.md) for why (an existing
Web-only `localStorage` preference predates the field, so a resolved default
can't be assumed on read the way it can for a field with no prior state
anywhere).

Every other section (Playback, the theme part of Appearance, Downloads &
Storage, Auto-Archive & Played Rules, Import/Export triggers, Accessibility,
Account & Privacy) is synced. `ShowSettings` per-show overrides sync the same
way, keyed by `(userId, showId)`.

## Settings data model shape

No new container: both documents already live in the `settings` Cosmos container,
partitioned by `/id`, distinguished by the `type` discriminator field. New settings
categories extend these two records with more fields rather than introducing new
documents, keeping "a user's settings" and "a user's override for one show" each a
single-partition point read:

```
UserSettings              (id = userId)
├─ unlistenedEpisodeCount : UnlistenedEpisodeCount   // existing
├─ playback                                          // #182
│  ├─ skipForwardSeconds / skipBackSeconds
│  ├─ autoPlayNext : bool
│  ├─ resumeBehavior : enum
│  ├─ defaultSpeed / defaultSilenceTrim / defaultVolumeBoost
├─ appearance                                        // #183, see appearance-settings.md
│  ├─ theme : Light|Dark|System|null                 // null = no synced preference set yet
                                                       // (appIcon and textSize are NOT UserSettings
                                                       // fields — appIcon is iOS-only/device-local,
                                                       // textSize has no field at all; see
                                                       // appearance-settings.md's Decisions)
├─ notifications                                     // #184, synced subset only
│  ├─ newEpisodesEnabled : bool
│  ├─ downloadCompleteEnabled : bool
├─ downloadsAndStorage                                // #185, see downloads-storage-settings.md
│  ├─ autoDownloadNewEpisodes : bool
│  ├─ autoDeleteRule : enum
│  ├─ autoDeleteAfterDays : int
├─ autoArchive                                        // #187
│  ├─ enabled : bool
│  ├─ afterPlayed / afterDays / afterEpisodeCount
├─ accessibility                                      // #192
├─ version : int                                     // existing, bumped per write

ShowSettings               (id = ShowSettings.BuildId(userId, showId),
                             i.e. "show:{Uri.EscapeDataString(userId)}:{Uri.EscapeDataString(showId)}")
├─ userId, showId
├─ unlistenedEpisodeCount : UnlistenedEpisodeCount?  // existing, null = inherit
├─ playbackSpeed / silenceTrim / volumeBoost : ...?  // #182, null = inherit
├─ notificationsEnabled : bool?                       // #184, null = inherit
├─ autoDownloadNewEpisodes : bool?                    // #185, null = inherit
├─ autoArchiveEnabled : bool?                         // #187, null = inherit
├─ version : int
```

Device-local settings (Data Usage & Network) are **not** part of either document —
they live in platform-native local storage (`UserDefaults`/`@AppStorage` on iOS,
browser `localStorage` or a Web-only settings table) and never round-trip through the
API, since they're not meaningful to sync.

`version` continues to be a plain per-document counter (see the existing comment on
`UserSettings`); it is not yet used for optimistic concurrency, and wiring it (or
Cosmos's ETag) into a check is still open follow-up work, unrelated to this IA.

## Web vs iOS parity

Same categories, same field-level defaults and per-show override semantics, native
navigation per platform:

- **iOS**: a single grouped `Form`/`List` (as `SettingsView` already is), each section
  a `Section`, each category that needs sub-options pushing to its own screen via
  `NavigationLink` rather than expanding inline. Widgets and Siri & Shortcuts are iOS
  categories that Web omits outright — no disabled/greyed-out placeholder in the Web
  list, since there's nothing there for a Web equivalent to configure.
- **Web**: one page (`Settings.razor` today) with the same sections rendered as
  in-page panels (current pattern), not a nested route per category — no client
  routing benefit here since there's no deep-linkable per-section state yet.

Both platforms read/write through the same `SettingsClient` abstraction that already
exists per-platform (`Kuulla.Web.Services.SettingsClient`, iOS's `SettingsClient`),
extended with new fields as each category issue implements them; this doc doesn't
change that abstraction's shape, only what settles into `UserSettings`/`ShowSettings`
underneath it.
