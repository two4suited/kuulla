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

- New synced field: `UserSettings.Theme` enum `Light | Dark | System`, default
  `System`. Making it synced (unlike today's Web-only `localStorage` value) is the
  point of putting it in this milestone at all — a user who sets dark mode on Web
  should see it on iOS too, per settings-architecture.md's default sync scope for
  every category that isn't inherently per-device.
- Web keeps `localStorage` as a pre-paint cache, not the source of truth: `theme.js`
  still applies the cached value immediately (so there's no flash of the wrong theme
  before the settings API responds), then `Settings.razor`'s load reconciles it
  against `UserSettings.Theme` from the server and re-applies/persists to
  `localStorage` if they differ. A change from the Settings screen calls
  `kuullaTheme` to apply immediately (same as the existing sidebar toggle) and pushes
  the new value through `SettingsClient`, same read-then-write pattern
  `UpdateUnlistenedEpisodeCountAsync` already uses.
- iOS gains a "Theme" picker driving `.preferredColorScheme(_:)` at the app root
  (`nil` for `System`), reading/writing the same `UserSettings.Theme` field through
  `SettingsClient.swift`.
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
├─ theme : Light|Dark|System = System   // new, synced
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
- Web's existing sidebar theme toggle (`NavMenu.razor`) is unchanged and stays as a
  quick-access shortcut to the same underlying value — it isn't replaced by the
  Settings-screen picker, the same way a per-show "Podcast settings" entry point and
  the global settings screen both write the same field without one replacing the
  other.
- No per-show override entry point needed for anything in this section.
