# App Store listing copy

Voice from `docs/brand.md` §2: plain, technical, show the number. Lead with the two
real bets — audio quality and sub-second sync.

---

## App name (30 char max)

```
Kuulla
```

## Subtitle (30 char max)

```
Podcasts, edited like radio
```
*(28 chars. The `docs/brand.md` tagline; ASC subtitles can't take the trailing period.)*

## Promotional text (170 char max — editable without review)

```
Pause on your phone, resume on your laptop — position, queue and downloads reconcile in under a second. High-bitrate, loudness-normalized audio on every device.
```
*(160 chars.)*

## Keywords (100 char max, comma-separated, no spaces)

```
podcast,player,sync,audio,offline,carplay,queue,transcript,playback,cross-device,streaming,episodes
```
*(99 chars.)*

## Description (4000 char max)

```
Kuulla is a podcast player built around two things most apps treat as afterthoughts: how the audio sounds, and whether it stays in sync.

PICKS UP WHERE YOU LEFT OFF — ON ANY DEVICE
Start an episode on your phone in the kitchen and finish it on your laptop in under a second. Playback position, your queue, subscriptions and downloads reconcile continuously and conflict-free. No "which device was I on?"

AUDIO QUALITY FIRST
High-bitrate streams, loudness-normalized so every show sits at the same level — no lunging for the volume between episodes. Gapless playback. Adjustable speed without the chipmunk artifacts.

BUILT FOR THE COMMUTE
Native CarPlay with Now Playing, chapters and your queue on the dash. Background audio and a sleep timer. Download over Wi-Fi and listen anywhere.

EVERYTHING IN THE OPEN
Elapsed time, chapter marks and "synced 2s ago" are shown, not hidden. Follow the transcript as it plays and tap any line to jump there. Search within a transcript to find the moment you're thinking of.

A REAL WEB PLAYER TOO
The same account, the same queue, in any browser at kuulla.app — so you're never stuck without your shows.

Kuulla is independent and has no ads.
```

## What's New (4000 char max — first release)

```
First public release.

• Cross-device sync for playback position, queue, subscriptions and downloads — sub-second and conflict-free
• High-bitrate, loudness-normalized playback with adjustable speed
• Native CarPlay
• Transcripts synced to playback, with in-transcript search
• Background audio, sleep timer, Wi-Fi-only downloads
• A matching web player at kuulla.app
```

---

## App Information

| Field | Value |
|-------|-------|
| **Primary category** | News *(or Entertainment — confirm against the catalog at submission)* |
| **Secondary category** | Entertainment |
| **Marketing URL** | `https://kuulla.app/welcome` — the landing page ([#348](https://github.com/sheridan-apps/kuulla/issues/348)) |
| **Support URL** | `https://kuulla.app/welcome` until a dedicated support page exists |
| **Copyright** | `2026 Kuulla` |
| **Age rating** | 4+ expected. The questionnaire asks about *your* content, not third-party feeds — Kuulla hosts none, so all "frequency of…" answers are None. Unrestricted web access is limited to opening episode/chapter links in an in-app browser; answer that question honestly (it typically lands 17+ if "yes" — decide whether to gate the chapter-link browser or accept 17+). |
| **Pricing** | Free, no in-app purchases |

## App Privacy (nutrition label)

The app talks to Kuulla's own API and signs in with Google. Fill in based on what the
backend actually stores:

| Data type | Collected? | Linked to user? | Used for tracking? | Purpose |
|-----------|-----------|-----------------|--------------------|---------|
| Email address | Yes (Google sign-in) | Yes | No | App Functionality, Account |
| User ID | Yes | Yes | No | App Functionality |
| Product interaction (playback position, subscriptions, queue) | Yes | Yes | No | App Functionality |
| Diagnostics / crash data | Only if a crash reporter is added — currently **No** |
| Device ID (APNs token) | Yes | Yes | No | App Functionality (new-episode notifications) |

No third-party analytics or ad SDKs → **"Data Not Used to Track You."** Confirm against
`src/Kuulla.Api` before submitting; this blocks review if wrong.

## Export compliance

Standard HTTPS/TLS only, no custom crypto → the standard exemption
(`ITSAppUsesNonExemptEncryption = NO`) applies. Add that key to `Info.plist` to skip the
per-build prompt.
