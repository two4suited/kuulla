# Accessibility settings

Spec for [#192](https://github.com/sheridan-apps/kuulla/issues/192)'s
"Accessibility" settings section, decided against
[settings-architecture.md](./settings-architecture.md)'s IA. Per the issue's own
"Output," this doc is both: the settings-section decision, and the accessibility
checklist the rest of this milestone's screens should be built against.

## Research

- **Pocket Casts**: adjustable text size, VoiceOver support notes, high-contrast
  considerations.
- **Overcast**: Dynamic Type support, VoiceOver labeling for playback controls.

## Existing state

Text rendering already uses SwiftUI's semantic text styles throughout (27
call sites across the iOS app use `.font(.headline/.body/.caption/...)`; zero use a
fixed-size `.font(.system(size:))`), which means Dynamic Type scaling already works
structurally almost everywhere — this isn't a from-scratch feature. VoiceOver
labeling is inconsistent: a handful of icon-only controls already set an explicit
`accessibilityLabel` (`DownloadButton`, `PlaylistsView`'s "New playlist" button,
`ShowDetailView`'s "Podcast settings" gear, `LibraryView`'s "New Episodes" button),
but the player screen (`EpisodeDetailView`) and `SettingsView` have none — icon-only
controls there (e.g. the playback-speed cycle button) fall back to whatever VoiceOver
infers from a bare SF Symbol, which is often unhelpful ("circle" instead of "1.5x
speed"). There are no custom animations anywhere in the iOS app (no
`withAnimation`/`.animation(...)` call sites) — nothing exists today that a
reduced-motion setting would need to gate.

## Decisions

### Text size / Dynamic Type

- No Kuulla-specific text-size setting — [appearance-settings.md](./appearance-settings.md)
  (#183) already decided this: Kuulla relies on the OS's Dynamic Type setting
  rather than a second, app-specific size axis.
- This issue's scope is narrower than "add Dynamic Type support" (already largely
  in place structurally): a verification pass confirming the screens this
  milestone builds — every new settings section (#182/#183/#188/#189/#190/#191)
  and the existing settings screen — render acceptably at the largest
  accessibility Dynamic Type sizes (no clipped labels, no unreadable truncation in
  a `Picker`/`Toggle` row), not a font-system rewrite.

### VoiceOver labeling

- Every icon-only control added by this milestone's settings work follows the
  existing `DownloadButton`/`ShowDetailView` convention: an explicit
  `accessibilityLabel` describing the action, not the icon (e.g. "Playback speed,
  1.5 times" rather than a bare speedometer glyph's default). This applies
  specifically to the new skip-forward/skip-back buttons
  ([playback-settings.md](./playback-settings.md), #182 — genuinely new controls,
  not existing ones needing a fix) and the existing playback-speed cycle button on
  `EpisodeDetailView`, which has no label today.
- Every new settings row (`Toggle`/`Picker`/`NavigationLink` added by this
  milestone) uses a plain text label as its title rather than an icon-only
  control, so it already gets a sensible VoiceOver label for free from SwiftUI's
  standard `Form`/`List` accessibility behavior — no extra annotation needed
  beyond what a normal `Form` row already provides.
- Destructive actions ([account-privacy-settings.md](./account-privacy-settings.md)'s
  "Delete Account", in particular) get an `accessibilityHint` describing the
  consequence, not just a label — a hint like "Permanently deletes your account and
  data" carries information a sighted user gets from surrounding red styling alone,
  which VoiceOver doesn't otherwise convey.

### High contrast

- No custom high-contrast theme or "Extra Dark" mode — already decided in
  [appearance-settings.md](./appearance-settings.md), which scoped Theme to
  Light/Dark/System. Standard SwiftUI system colors (used throughout, no custom
  hard-coded hex colors found in the settings screens) already respond to iOS's
  Increase Contrast accessibility setting automatically; there's nothing
  Kuulla-specific to add here.

### Reduced motion

- No reduced-motion setting for this milestone — there are no custom animations
  anywhere in the app today for one to gate. This isn't "out of scope," it's "N/A
  until there's motion to reduce": the guideline for *future* work (this milestone
  and beyond) is that any `withAnimation`/`.animation(...)` added later should be
  wrapped in a `@Environment(\.accessibilityReduceMotion)` check, the same way any
  new icon-only control should get an `accessibilityLabel` — a standing convention
  this doc establishes, not a settings toggle Kuulla needs to build (iOS's own
  Reduce Motion setting is what a `reduceMotion` environment read already reflects).

### Settings UI for this section

- A lightweight "Accessibility" row, following the same "informational, not a
  configuration surface" pattern as [widgets-settings.md](./widgets-settings.md)
  (#190): brief text noting that Kuulla follows the device's Dynamic
  Type/Increase Contrast/Reduce Motion settings automatically, with a link to the
  system Settings app's Accessibility section. There's no Kuulla-owned toggle to
  add here — every actual decision above either defers to an OS-level setting
  Kuulla already respects, or is a development-time labeling convention applied
  across the other sections' controls, not a user-facing preference of its own.

## Data model

No `UserSettings`/`ShowSettings` changes — nothing in this section is a stored
preference. Synced-scope classification (per
settings-architecture.md's [Sync scope](./settings-architecture.md#sync-scope))
doesn't apply since there's no field.

## UI

- iOS `SettingsView.swift` / Web `Settings.razor`: an "Accessibility" row/section
  with the informational text and system-Settings link described above.
- No per-show override entry point — nothing in this section is a per-show
  setting.
