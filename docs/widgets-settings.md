# Widgets settings

Spec for [#190](https://github.com/sheridan-apps/kuulla/issues/190)'s "Widgets"
settings section, decided against
[settings-architecture.md](./settings-architecture.md)'s IA (iOS-only).

## Research

- **Pocket Casts**: home-screen widgets (Now Playing, Up Next), a lock-screen
  widget, Apple Watch complications. No dedicated in-app "Widgets" settings screen
  with toggles — widgets are added/removed via iOS's own widget gallery.
- **Overcast**: a Now Playing widget and a lock-screen widget, same "added via the
  OS gallery, not an app setting" model.

## Existing state

There is no widget extension target in `Kuulla.xcodeproj` today (only the app,
unit-test, and UI-test targets) — this is greenfield. There's also no shared
"what's currently playing" data source a widget process could read: no
`MPNowPlayingInfoCenter`/`MPRemoteCommandCenter` integration exists yet (that's
[#116](https://github.com/sheridan-apps/kuulla/issues/116) "Now Playing info &
remote command center," open under the
[CarPlay Support](https://github.com/sheridan-apps/kuulla/milestone/17) milestone —
the "shared foundation" the CarPlay milestone's own description refers to), and
there's no App Group entitlement configured for sharing data between the main app
and an extension process (the current entitlements file only has `aps-environment`
for push).

## Decisions

### Which widgets to build

- **Now Playing** (home screen + Lock Screen): current episode title, show
  artwork, and progress. Home Screen and Lock Screen widgets share the same
  `WidgetKit` timeline provider and view, per Apple's standard pattern — not two
  separate implementations.
- **Up Next** (home screen only): the next 1–3 queued episodes' titles/artwork, a
  static-refresh list rather than live progress.
- No Apple Watch complications (Pocket Casts' extra) — Kuulla has no watchOS app
  or target today; a complication needs one, which is its own milestone-sized
  effort, not a widgets settings decision.
- No interactive widget controls (play/pause buttons directly on the widget,
  possible via WidgetKit's `Button`/`Toggle` intents on iOS 17+) for this issue —
  scoped out because there is no App Intent-based playback control path yet either
  (the same gap #116 exists to close for remote-command-center controls); adding
  one is implementation work for whichever issue actually builds the Now Playing
  widget, not a decision this settings-catalog spec needs to force ahead of time.

### Data source: depends on #116, not a separate mechanism

- Both widgets read from a shared App Group container (a new
  `group.com.kuulla.app` App Group entitlement — matching the app's existing
  `com.kuulla.app` bundle identifier — added to both the main app target and the
  new widget extension target) that the main app writes "what's currently
  playing" / "what's queued" into.
- The Now Playing widget's data should come from the **same** now-playing state
  #116 establishes (`MPNowPlayingInfoCenter`), not a second, independently
  maintained "what's playing" tracker — #116 is already the natural single source
  of truth for that once it exists, publishing to the shared container being the
  one new piece of plumbing on top of it. This issue doesn't re-decide #116's own
  scope, only that Widgets consumes it rather than duplicating it.
- The Up Next widget reads from the existing Up Next queue (the same data
  `PlaylistDetailView`/the sync-provided playlist already represents), mirrored
  into the shared container whenever it changes — no new queue concept, just a
  second place that data needs to be written for the widget process to read it
  without a network round-trip of its own (widgets should render from local shared
  state, not make their own API calls on every timeline refresh).

### Settings UI

- No per-widget enable/disable toggle in Kuulla's own settings — iOS widgets are
  added and removed entirely through the OS's own widget gallery (long-press the
  home screen / Lock Screen editor), the same "OS owns this, not the app" model
  Pocket Casts and Overcast both follow; there's no API for an app to add/remove
  its own widgets on a user's behalf, so a Kuulla-side toggle would have nothing
  to actually control.
- The "Widgets" settings row is a single informational screen — brief instructions
  for adding a Kuulla widget (iOS's standard long-press flow), not a
  configuration surface. This directly answers the issue's own "Widget
  configuration options exposed in Settings" question: none beyond this help
  text, because there's no per-widget setting to expose.

## Data model

No `UserSettings`/`ShowSettings` changes — device-local, per
settings-architecture.md's [Sync scope](./settings-architecture.md#sync-scope)
(same treatment as Siri & Shortcuts): a home-screen widget's layout and content
are properties of *this* device's home screen, not a synced preference. Nothing
here is a settings toggle at all — it's the shared-container plumbing described
above plus a static help screen.

## UI

- iOS `SettingsView.swift` only (Web has no home screen, so no Web equivalent —
  hidden entirely, matching how settings-architecture.md already scopes this
  section): a "Widgets" row navigating to the informational "How to add widgets"
  screen.
- No per-show override entry point — nothing in this section is a per-show
  setting.
