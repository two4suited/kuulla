# Appearance settings

Spec for [#183](https://github.com/sheridan-apps/kuulla/issues/183)'s "Appearance"
settings section, decided against
[settings-architecture.md](./settings-architecture.md)'s IA (section 2). Covers
theme, app icon, and text size — and reconciles them with the theme toggle Web
already ships today.

## Research

- **Pocket Casts**: light/dark/system theme plus several named color themes, custom
  app icon selection, an "Extra Dark" mode for OLED screens.
- **Overcast**: light/dark/system, a handful of tinted icon options, an adjustable
  in-app text size independent of the OS setting.

## Existing state

Web already has a working theme toggle (`src/Kuulla.Web/wwwroot/theme.js`,
`NavMenu.razor`'s sidebar switch): light/dark/system, stored in `localStorage`
under `kuulla-theme`, applied to `<html data-bs-theme>` before first paint. It is
entirely device-local today — no `UserSettings` field, no server round-trip. iOS has
no theme control at all (SwiftUI just follows the system appearance), and no
alternate-app-icon or in-app text-size support.

## Decisions

### Theme

- New synced field: `UserSettings.Theme` enum `Light | Dark | System`, **nullable**
  (`Theme?`, default `null`) — not a plain defaulted field like `NotificationsEnabled`.
  Unlike a brand-new preference, Theme already has an existing source of truth on
  Web (`localStorage`'s `kuulla-theme`) that predates this field: every existing
  `UserSettings` document and every not-yet-updated sync client omits `Theme`
  entirely, and a plain default of `System` on read would silently overwrite a Web
  user's real dark-mode preference the first time it round-trips, or clobber it from
  a second device that hasn't picked a theme yet. `null` distinguishes "no synced
  preference has been set yet" from an explicit choice of `System`, and — like
  `ShowSettings`'s nullable override fields — a client that reads `null` must leave
  it alone on write-back rather than filling in a resolved default, so an
  old/not-yet-migrated device's sync round-trip can't stomp a value another device
  already set.
- **Migration**: the first time Web's `Settings.razor` loads and finds
  `UserSettings.Theme == null`, it uploads its current resolved `localStorage`
  value (`Light` or `Dark` if one is stored, `System` if `kuulla-theme` is unset) as
  the new synced value, one time — turning the pre-existing device-local preference
  into the seed for the synced field instead of discarding it. iOS, which has no
  prior preference to preserve, just resolves a `null` read as `System` for display
  and playback purposes without writing anything back until the user actively picks
  a theme from the new picker.
- Web keeps `localStorage` as a pre-paint cache, not the source of truth, with one
  wrinkle `theme.js` already has: `System` is represented there by the *absence* of
  the `kuulla-theme` key (that's what makes its `matchMedia` OS-change listener a
  no-op once a key exists — `readStoredTheme() === null` gates it). Reconciliation
  against the synced value must preserve that: persisting `Light`/`Dark` writes the
  key as today, but persisting a synced `System` means *clearing* the key rather
  than writing the string `"system"` — writing the literal string would permanently
  disable the OS-follow listener, which only checks for a missing key. Resolve
  `System` to the live OS preference once for the immediate `data-bs-theme` paint,
  but store nothing.
- The existing sidebar quick-toggle (`NavMenu.razor`'s `.theme-toggle` button,
  `onclick="window.kuullaTheme?.toggle()"`) stays as a visible control, but
  `kuullaTheme.toggle()` itself changes from a `localStorage`-only write to also
  pushing the new value through `SettingsClient` (fire-and-forget, same as any other
  quick toggle) — otherwise a user who changes theme from the sidebar would see it
  silently reverted on the next settings load/sync reconciliation, since the synced
  field would never have learned about the change made outside the Settings screen.
  A change from the Settings screen's own picker uses the same
  apply-immediately-then-persist flow, through `SettingsClient`'s existing
  read-then-write pattern (`UpdateUnlistenedEpisodeCountAsync`).
- iOS gains a "Theme" picker driving `.preferredColorScheme(_:)` at the app root
  (`nil` for both `System` and unset/`null`), reading/writing the same
  `UserSettings.Theme` field through `SettingsClient.swift`. On the local SwiftData
  mirror (`UserSettingsRecord`), the new `theme` attribute must be declared
  `ThemeOption?` (optional, no inline default) rather than following
  `notificationsEnabled`'s non-optional-with-default pattern — `UserSettingsRecord`
  already documents (see its migration comment above `notificationsEnabled`) that a
  non-optional attribute with no default fails SwiftData's lightweight migration
  outright for existing installs; an optional attribute needs no such default and
  is the same nullable representation the synced field itself uses.
- No separate named color themes or "Extra Dark" mode (Pocket Casts' extras) — three
  options (Light/Dark/System) match Overcast's scope and cover the actual ask
  (dark-mode support), without a component-by-component design pass for a second
  dark palette.
- No per-show override — a show's per-episode listening screen doesn't need its own
  theme, unlike playback speed or auto-skip which vary by show content.

### App icon

- iOS-only, matching how Widgets (#190) and Siri & Shortcuts (#191) are scoped in
  settings-architecture.md — no Web equivalent since Web has no home-screen icon to
  swap.
- Device-local, not a `UserSettings` field: like Widgets/Siri & Shortcuts, an
  alternate app icon is applied via `UIApplication.setAlternateIconName` and is a
  property of *this installed app on this device*, not a preference a second device
  could receive and apply — a phone and an iPad don't share a home screen. This
  differs from Theme (a rendering preference, meaningfully identical across devices)
  even though both are visual settings.
- A small fixed set of icon options (default + 2–3 alternates) shipped as additional
  `CFBundleAlternateIcons` entries in the iOS target; no user-uploadable custom icon.

### Text size

- No new in-app text-size control (no font-scale slider independent of the OS
  setting, unlike Overcast). Kuulla adopts the platform's Dynamic Type
  (`@Environment(\.dynamicTypeSize)`, standard `Font` text styles) rather than a
  second, app-specific size axis a user would have to discover and set separately
  from their phone's actual text-size setting.
- This issue only decides *whether to expose a Kuulla-specific text-size setting*
  (no); *making Dynamic Type actually work correctly* across the settings/player
  screens — sizing, truncation, VoiceOver labels — is
  [#192](https://github.com/sheridan-apps/kuulla/issues/192) Accessibility's scope,
  not re-litigated here.
- No Web equivalent needed — browser zoom/OS text-size settings already apply to a
  responsive web page without app-specific support.

## Data model

Extends `UserSettings` (`Kuulla.Api.Models`) — no changes to `ShowSettings`:

```
UserSettings                       (id = userId)
├─ theme : Light|Dark|System|null = null   // new, synced; null = no synced preference yet
                                            // (Web migrates its existing localStorage value in on
                                            // first load — see "Decisions" above — rather than a
                                            // client resolving null to a default and writing it back)
```

App icon has no `UserSettings` field (device-local, per "Decisions" above — same
treatment as Widgets/Siri & Shortcuts in settings-architecture.md's
[Sync scope](./settings-architecture.md#sync-scope)); it's read/written directly via
`UIApplication.setAlternateIconName`/`alternateIconName` with no server round-trip.
Text size has no field at all — it's the OS's Dynamic Type setting, not something
Kuulla stores.

## UI

- iOS `SettingsView.swift` / Web `Settings.razor`: an "Appearance" section (position
  2) with:
  - "Theme" picker: Light / Dark / System.
  - iOS only: "App Icon" row navigating to an icon-grid picker screen.
- Web's existing sidebar theme toggle (`NavMenu.razor`) stays as a visible
  quick-access shortcut to the same underlying field (its `kuullaTheme.toggle()`
  now also pushes to `SettingsClient`, per "Decisions" above) — it isn't replaced by
  the Settings-screen picker, the same way a per-show "Podcast settings" entry point
  and the global settings screen both write the same field without one replacing
  the other.
- No per-show override entry point needed for anything in this section.
