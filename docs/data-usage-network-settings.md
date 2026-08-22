# Data usage & network settings

Spec for [#186](https://github.com/sheridan-apps/kuulla/issues/186)'s "Data Usage &
Network" settings section, decided against
[settings-architecture.md](./settings-architecture.md)'s IA and against the
[Offline Downloads](https://github.com/sheridan-apps/kuulla/milestone/28) milestone's
download manager ([#174](https://github.com/sheridan-apps/kuulla/issues/174)–
[#180](https://github.com/sheridan-apps/kuulla/issues/180)). This doc decides *over
what connection* streaming and downloading happen; see
[downloads-storage-settings.md](./downloads-storage-settings.md) (#185) for *what*
gets downloaded and kept.

## Research

- **Pocket Casts**: a dedicated "Data usage" screen with independent Wi-Fi-only
  toggles for streaming and downloading, plus mobile-data usage warnings.
- **Overcast**: a single "Only stream/download over Wi-Fi" toggle, with a cellular
  data usage estimate shown elsewhere in the app.

## Decisions

### Separate toggles for streaming vs. downloading

Two independent toggles, not Overcast's combined one:

- `WifiOnlyStreaming: bool`, default `false` — restricting *streaming* to Wi-Fi is a
  much bigger behavior change (playback simply refuses to start on cellular) than
  restricting downloads, so it defaults off; a user who wants that restriction opts
  in explicitly.
- `WifiOnlyDownloads: bool`, default `true` — downloading is the case #180 ("Wi-Fi
  only downloads setting") already calls out as wanting a default-on toggle, since an
  unattended auto-download (per #185's auto-download rules) silently burning cellular
  data on a large backlog is a worse surprise than a stalled/queued download. This
  field **is** #180's setting — #180 implements the toggle described here rather than
  inventing its own; this doc is that field's spec, not a separate parallel one.

Pocket Casts' two-toggle shape rather than Overcast's one is deliberate: someone
commuting on a data plan might happily stream (bounded, stops when they stop
listening) while still wanting downloads (potentially many episodes, unbounded)
held to Wi-Fi — collapsing that into one toggle can't express it.

### No bandwidth/quality tradeoff setting

No "lower bitrate on cellular" setting for this milestone. `CLAUDE.md`'s key design
decision is "audio quality is the top priority — prefer higher bitrate and proper
normalization over bandwidth savings"; a per-connection quality knob works directly
against that stated priority, and the two Wi-Fi-only toggles above already give a
user who's data-conscious a way to avoid the cost entirely (don't stream/download
on cellular) rather than degrading what they do hear. Revisit only if a future
milestone changes that quality priority.

### Device-local, not synced

Both toggles are **device-local settings**, per
[settings-architecture.md's Sync scope](./settings-architecture.md#sync-scope) (which
already calls this section out as the sync exception) — stored in `UserDefaults`
(iOS) / browser `localStorage` (Web), with no `UserSettings`/`ShowSettings` field and
no API round-trip. A user's phone being on Wi-Fi tells you nothing about whether
their laptop is, so a synced value would just be wrong on the second device as often
as it was right.

## Data model

No `UserSettings`/`ShowSettings` change — per the device-local decision above, these
two booleans live entirely in platform-native local storage:

```
iOS:  @AppStorage("wifiOnlyStreaming") : Bool = false
      @AppStorage("wifiOnlyDownloads") : Bool = true

Web:  localStorage["wifiOnlyStreaming"] = "false"
      localStorage["wifiOnlyDownloads"]  = "true"
```

## UI

- iOS `SettingsView.swift` / Web `Settings.razor`: a "Data Usage & Network" section
  (per settings-architecture.md's ordering, position 6) with two toggles: "Stream
  over Wi-Fi only" and "Download over Wi-Fi only."
- No per-show override — a connection restriction is a device/session property, not
  a per-podcast preference, so this section has no "Podcast settings" entry point
  (unlike #185's auto-download override).

## Interaction with the Offline Downloads download manager

- `WifiOnlyDownloads` is read by `DownloadManager` (#175) before starting a download,
  and by `NWPathMonitor` observation (#180) to pause/resume in-flight downloads as
  Wi-Fi availability changes — this doc decides the setting's existence, default, and
  storage; #180 owns the actual `NWPathMonitor` wiring and queueing behavior.
- `WifiOnlyStreaming` has no dependency on the Offline Downloads milestone — it
  gates `AudioPlayer`'s remote-stream path directly, independent of #174–#180.
