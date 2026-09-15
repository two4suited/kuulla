# Audio engine research: speed quality, silence, ads, and files

Deep-dive into `ios/Kuulla/Kuulla/AudioPlayer.swift` and `SmartSpeedProcessor.swift`
prompted by "the audio sounds fun at 2x and really funny at 3x", plus a look at where
the engine stands on ad handling, dead-air trimming, and downloaded-file robustness.
Findings first, then what shipped with this document, then the roadmap for the parts
that need their own issues. Tracked in
[#774](https://github.com/two4suited/kuulla/issues/774).

## TL;DR

| # | Finding | Severity | Status |
|---|---------|----------|--------|
| 1 | Pitch correction uses `.timeDomain`, which warbles/stutters from ~2x up | High — the reported symptom | **Fixed**: switched to `.spectral` |
| 2 | Trim Silence multiplies the session rate by 4, so a 3x session skips at **12x**, and the rate-change latency bleeds that 12x onto the first words after every pause | High — the "really funny at 3x" symptom when trim is on | **Fixed**: skip rate capped at 6x, and playback rewinds to the exact point sound resumed so no words are lost; the splice design in #5 is still the better trim |
| 3 | Voice Boost runs an unconditional `tanh()` limiter with a -9 dBFS RMS target, so ordinary-level speech is gained past full scale and soft-clipped | High — audible distortion whenever Voice Boost/SmartSpeed is on | **Fixed**: peak-aware gain, soft-knee limiter, attack/release smoothing |
| 4 | Downloaded files take their extension from `suggestedFilename` (or "mp3"), so an M4A behind an extension-less URL — or a 4xx/HTML error page — is saved as `.mp3`, marked complete, and fails to play | Medium | **Fixed**: magic bytes → Content-Type → known extension; non-2xx and web-page payloads mark the download failed |
| 5 | Trim Silence only saves ~6% of listening time on speech with generous pauses; a splice-based trim would save ~18% on the same audio | Medium — feature under-delivers | Roadmap: analyze-ahead + `AVMutableComposition` edit list for downloads |
| 6 | VBR MP3s without a Xing header get an estimated duration from AVFoundation (wrong progress, wrong outro-skip point, imprecise seeks) | Low | **Not changed** — measured: precise timing costs 0.5–1 s per play on real episodes and the estimate was already within 0.3 s; see finding 6 |
| 7 | No ad handling of any kind; chapters and transcripts exist but nothing marks or skips ads | Feature gap | Roadmap: chapter-title skip now, on-device transcript classification later |

## How the engine works today

```
AVPlayerItem(url) ── audioTimePitchAlgorithm ── rate = playbackSpeed ──▶ AVPlayer ──▶ output
        │
        └── AVMutableAudioMix ── MTAudioProcessingTap (PostEffects) ── SmartSpeedProcessor.process()
                                                                          ├─ RMS per buffer
                                                                          ├─ gain stage (Voice Boost / volume offset)
                                                                          └─ SilenceRunDetector ──▶ onSilenceStateChanged
                                                                                                        │ (main thread)
                                                                              player.rate = speed × 4 ◀─┘  while silent
```

- Speed is `AVPlayer.rate` with a pitch-correction algorithm on the item. There is no
  custom decode pipeline; AVPlayer handles streaming, buffering, and local files.
- SmartSpeed/Voice Boost/Trim Silence are an `MTAudioProcessingTap` on the item's audio
  mix. The tap only sees audio that is about to render — it has no lookahead — so
  "trimming" is implemented as *speeding up* through a pause once it has lasted 0.8 s,
  and dropping back to the configured rate when sound resumes.
- `docs/smartspeed-spike.md` chose this over an `AVAudioEngine` migration because
  AVAudioEngine has no progressive-streaming input. That reasoning still holds; nothing
  below requires leaving AVPlayer.

## Findings

### 1. `.timeDomain` is the wrong pitch algorithm above ~1.5x

`makeSmartSpeedProcessorIfNeeded` set `item.audioTimePitchAlgorithm = .timeDomain` on
every item. AVFoundation offers three pitch-preserving stretchers:

| Algorithm | How it works | Character at 2x–3x on speech |
|-----------|--------------|------------------------------|
| `.timeDomain` | Overlap-add of short waveform grains (WSOLA-style) | Grains shrink as rate rises; vowels warble, consonants stutter/double. Cheap. |
| `.spectral` | Phase vocoder (same engine as `AVAudioUnitTimePitch`) | Smooth vowels, slight "phasey" softening of transients. Higher CPU, still trivial on any iOS 17 device. |
| `.varispeed` | Resampling, no pitch correction | Chipmunk. Reference only. |

Apple's header notes describe `.timeDomain` as "suitable for voice", which is why it
was picked, but that describes its cost/quality trade-off near 1x, not its behavior at
the top of Kuulla's preset range (up to 3x, and up to 12x during a silence skip — see
finding 2). Pocket Casts' iOS player uses `AVAudioUnitTimePitch`, i.e. the spectral
engine, for exactly this reason.

**Evidence you can listen to.** `tools/audio/render-speeds.swift` renders a sample
through each algorithm with a scaled `AVMutableComposition` + `AVAssetExportSession`,
which use the same `AVAudioTimePitchAlgorithm` implementations `AVPlayer` does. The
`*_CURRENT` files are what the app shipped; the `*_spectral` files are the fix. The
12x file is what Trim Silence was playing during a confirmed pause at 3x.

**Fix shipped:** `.spectral` unconditionally. The test
`testPlaySetsSpectralPitchAlgorithm` guards it.

### 2. Silence skip compounds to 12x and bleeds onto the next sentence

`silenceSkipRateMultiplier = 4.0` was applied *on top of* the session speed:

| Session speed | Skip rate (before) | Skip rate (after cap) |
|---------------|--------------------|-----------------------|
| 1x | 4x | 4x |
| 1.5x | 6x | 6x |
| 2x | 8x | 6x |
| 3x | **12x** | 6x |

That would be harmless if the rate change were instantaneous, but the path from the tap
noticing sound has resumed to the player actually slowing down is:
tap callback (already ahead of the speaker by AVPlayer's render-ahead buffer) →
`DispatchQueue.main.async` → `player.rate = speed` → AVPlayer re-times its audio
pipeline. That is on the order of 100–300 ms of wall-clock, and during it the audio
keeps playing at the skip rate. Item-seconds of *speech* consumed at the skip rate
during that window:

| Skip rate | 100 ms latency | 300 ms latency |
|-----------|----------------|----------------|
| 4x | 0.4 s | 1.2 s |
| 6x | 0.6 s | 1.8 s |
| 12x | 1.2 s | 3.6 s |

At 12x, the first one to four seconds after every pause — usually the first word or
two of the next sentence — is played as an unintelligible chirp. That is a plausible
match for "really funny at 3x" on its own, and it stacks with finding 1, since
`.timeDomain` at 8–12x is pure artifact.

The exact latency has not been measured on a device; it is bounded below by AVPlayer's
render-ahead buffer and the main-thread hop, and the numbers above are the
plausible range. Measuring it is on the roadmap (instrument the tap's `itemTime` jump
after a rate change).

**Fix shipped, two parts:**

- `SmartSpeedProcessor.silenceSkipRate(forPlaybackSpeed:)` = `max(speed, min(speed × 4, 6))`
  bounds how fast anything can be playing when the restore lands. The #680 time-saved
  accounting uses the same capped rate (`AudioPlayer.silenceTimeSaved`), so the
  lifetime counter stops over-claiming at high speeds.
- **Rewind to the resume point.** The detector already knows the exact `itemTime` at
  which sound came back; it is now passed through `onSilenceStateChanged`, and after
  restoring the rate `AudioPlayer` compares it with the output position. If the output
  has run more than 50 ms past it, a zero-tolerance seek jumps back there and the
  swallowed words are replayed at the normal rate (`shouldRewindAfterSilence`). The
  bleed is then bounded by the seek's own tiny discontinuity, not by the latency, at
  every speed — including 1.5x, where the cap alone would not have engaged.

The rewind is the right fix for this pipeline; the splice design in finding 5 is still
the better *trim*, because it removes the pause instead of racing through it.

### 3. Voice Boost distorts ordinary speech

Three compounding problems in the gain stage:

- **Unconditional `tanh` limiter.** Whenever the combined gain was > 1, *every* sample
  went through `tanhf(sample × gain)`. `tanh(x) ≈ x` only below ~0.3; at 0.5 it is
  already 0.46, at 1.0 it is 0.76. So any boosted passage had its whole waveform
  compressed and its harmonics smeared — audible as a fuzzy, "radio" edge on normal
  dialogue, not just on peaks.
- **Target too hot.** `boostTargetLevel = 0.35` RMS is about -9 dBFS. Speech has a
  crest factor of roughly 12–15 dB, so hitting that RMS needs peaks at +3 to +6 dBFS —
  impossible without clipping. A normal podcast (RMS ~0.1, -20 dBFS) got the full 4x
  gain and lived permanently inside the limiter.
- **Symmetric, slow smoothing.** 15% of the distance per buffer in both directions
  means a loud passage arriving after a boosted quiet one is over-gained for several
  buffers (pumping through the limiter), while the same slowness on the way up is
  fine.

**Fix shipped:**

- `boostTargetLevel = 0.2` (≈ -14 dBFS RMS, in line with the -16 LUFS spoken-word
  norm) and `boostGain(forLevel:peak:)` additionally caps gain so the buffer's peak
  stays under `peakCeiling = 0.95`. Steady-state program material no longer touches
  the limiter at all.
- `softLimit(_:)`: identity up to ±0.8, then the remaining headroom is compressed with
  `tanh` so the curve is continuous in level and slope at the knee and never exceeds
  ±1. Ordinary samples are an exact linear multiply.
- `boostTargetLevel = 0.2` (≈ -14 dBFS RMS, in line with the -16 LUFS spoken-word
  norm) drives the smoothed gain; the per-buffer peak clamp `peakLimitedGain` is applied
  *after* smoothing and never fed back into the state, so a single plosive clamps only
  its own buffer (masked by the transient) instead of driving the attack and ducking the
  whole passage for the release time. Steady-state program material never reaches the
  limiter; only the fixed volume offset can.
- Asymmetric smoothing: `gainAttackFactor = 0.5` (down fast), `gainReleaseFactor = 0.1`
  (up slowly), with the state floored at unity so a loud passage cannot leave a
  sub-unity dead zone the next quiet passage has to climb out of.
- Gain is *held* through buffers under the silence threshold rather than re-targeted
  from room tone, so pauses no longer swell the noise floor and the first word after a
  pause starts at the gain the previous one ended on.

Coverage: `SmartSpeedProcessorGainStageTests` (normal-level speech passes through
bit-identical; attack faster than release; a transient clamps only its own buffer; gain
holds through silence; unity floor; boosted peaks stay inside full scale) plus
pure-function tests for `softLimit` and `peakLimitedGain`.

### 4. Downloaded-file type handling

AVFoundation identifies a **local** file's container by its path extension; it does
not sniff a `file://` URL the way it honors an HTTP `Content-Type`. `DownloadManager`
saved every download as `<episodeId>.<suggestedFilename extension>` with `"mp3"` as
the fallback. Real enclosure shapes that broke:

- Extension-less or script-style endpoints (`/download/12345`, `/play.php?id=…`,
  `/episodes/42/audio`) serving AAC/M4A → saved as `.mp3` or `.php` → "format not
  recognized" at play time, while streaming the same URL works.
- A `.mp3` URL that is actually an MP4 container (some hosts transcode behind a
  stable URL) → same failure.
- A 200 response whose body is an HTML page (expired signed link, geo-block, sign-in
  interstitial) → saved as `.mp3`, marked `.complete`, fails silently at play time.
  `resolvedPlaybackURL` only falls back to streaming when the file is *missing*, not
  when it is garbage.

**Fix shipped:** `DownloadManager.audioFileExtension(mimeType:suggestedFilename:headerBytes:)`
trusts, in order: the file's own container signature (`ID3`, `ftyp`, `RIFF`, `FORM`,
`fLaC`, `OggS`, `caff` — the ground truth, since the container *is* what the bytes
say), then the declared audio `Content-Type` (`audio/mpeg`, `audio/mp4`,
`audio/x-m4a`, `audio/aac`, …), then a *known audio* extension from the URL, then the
weak two-byte MPEG/ADTS frame sync, then `mp3`. `isAcceptablePayload` refuses any
non-2xx response outright (a download task "completes" a 403/404 just like a 200,
with the error body as the file) and `looksLikeAudioContent` refuses web pages:
markup in the leading bytes, or a declared `text/html` body smaller than 256 KB.
Anything that sniffs as audio is kept whatever the header says, and a large
unrecognized octet stream behind a `text/html`-for-everything host is kept too, so a
real MP3 with junk before its first frame is never refused forever. A refused payload
is marked `.failed` from the task's completion callback, in the same main-queue block
that clears its in-flight bookkeeping, so tap-to-retry is never shown while the retry
would still be rejected as a duplicate.

Related, not fixed here:

- **Ogg Vorbis / Opus enclosures** cannot play at all — AVFoundation decodes Opus only
  inside CAF/MP4, and never Vorbis. They are rare in podcast feeds but not unheard of
  (some Podcasting 2.0 / Funkwhale-hosted shows). The API could store the enclosure
  `type` attribute (`PodcastFeedClient` currently drops it) so the client can warn
  before a doomed download.
- `Episode.bitrateKbps` is derived from `length / duration`; for a VBR file it is only
  a mean. Fine for display.

### 5. Trim Silence removes very little

Measured with `tools/audio/measure-pauses.swift` on a 43.9 s spoken sample with
12.5 s of silence across 54 runs (7 of them ≥ 0.8 s), using the processor's own
threshold (-42 dBFS RMS over 20 ms windows):

| Speed | Current design saves | Splice pauses down to 0.25 s |
|-------|----------------------|------------------------------|
| 1x | 2.61 s (5.9 % of listening time) | 7.88 s (18.0 %) |
| 2x | 1.30 s (5.9 %) | 3.94 s (18.0 %) |
| 3x | 0.87 s (5.9 %) | 2.63 s (18.0 %) |

Why the gap:

- The first 0.8 s of every pause plays at normal speed (the confirmation window), and
  most conversational pauses are 0.3–1.0 s, so they never trigger at all.
- The remainder is only *sped up* by 4x (now ≤ 6x), not removed, and the rate change
  lags (finding 2).
- The sample is TTS with generous pauses; real podcasts have more 0.3–0.7 s pauses and
  fewer long ones, so the current design's share is likely *lower* in practice.

Overcast-style trimming (the benchmark users compare against) removes most of every
pause above a few hundred milliseconds. Getting there needs lookahead, which the tap
cannot provide. The design that fits the existing AVPlayer architecture:

**Analyze-ahead + edit list (recommended, downloads first).**

1. When an episode is downloaded (or on first play of a downloaded file), decode it
   with `AVAssetReader` in a background task — many times faster than real time — and
   produce a *silence map*: `[(start, end)]` of runs below threshold, using the same
   detector.
2. Build an `AVMutableComposition` that inserts only the non-silent ranges (keeping a
   `floor` of ~0.2–0.3 s of each pause so speech keeps its rhythm), and play that
   composition instead of the raw asset. AVPlayer plays composition edits gaplessly and
   sample-accurately; the pitch algorithm then only ever runs at the user's chosen
   speed. No 6x/12x bursts, no lost words, no rate-change latency.
3. Keep a two-way time map (composition time ↔ source time) so `currentTime`,
   progress sync, chapters, transcript highlighting, and outro-skip keep working in
   source time. This is the bulk of the work.
4. Cache the silence map alongside the download record so it is computed once.
5. Streams keep the current rate-based trim as the degraded mode (and the app already
   steers users toward downloads).

The same edit-list mechanism is exactly what ad skipping needs (finding 7), which is
the strongest argument for building it: one "excluded ranges" model, two features.

### 6. VBR MP3 duration and seek accuracy — measured, left alone

`AVPlayerItem(url:)` builds an `AVURLAsset` with default options, so AVFoundation
estimates an MP3's duration from the first frames' bitrate when there is no Xing/Info
header, and the app uses `item.duration` for the progress bar, "time remaining",
`checkAutoSkipOutro`, and `approachingEnd`.

The obvious fix — `AVURLAssetPreferPreciseDurationAndTimingKey` for `file://` assets —
was tried and reverted after measuring it on three real downloaded episodes from the
simulator's app container (an M-series Mac, so an iPhone is slower):

| File | Estimated duration | Precise duration | Load time, estimated | Load time, precise |
|------|--------------------|------------------|----------------------|--------------------|
| 64.4 MB MP3 | 3985.79 s | 3985.50 s | 31 ms | 1048 ms |
| 27.6 MB MP3 | 1724.55 s | 1724.55 s | 0 ms | 473 ms |
| 48.1 MB MP3 | 2982.37 s | 2982.35 s | 2 ms | 616 ms |

There is no packet table in an MP3; "precise" means walking every frame header, and
that read lands on the tap-to-play path of exactly the episodes that should start
instantly. The estimate was within 0.3 s on all three, because modern hosts write
Xing/Info headers. If a headerless VBR file ever matters, compute the precise
duration once at download time in the background and store it on the download
record; do not pay for it per play.

### 7. Ads: nothing today, and what would actually work

There is no ad-related code. What exists that could be built on:

- **Chapters** (`podcast:chapters`, parsed server-side into `EpisodeChapter` with
  start/title/img/url). Many shows that publish chapters title ad breaks ("Sponsor",
  "Ad break", "A word from our sponsors"), and sponsor chapters usually carry a `url`.
  Note the Podcasting 2.0 `toc: false` flag is *not* an ad marker (it hides
  metadata-only chapters), so it should not be used as one.
- **Transcripts** (`podcast:transcript`, fetched and normalized on demand into timed
  `TranscriptSegment`s). Ad reads are easy to classify from text.
- **Silence/loudness** at the tap: dynamically inserted ads are usually a different
  loudness and often bracketed by dead air, but that alone is a weak signal.

The catch that shapes the design: **dynamic ad insertion (DAI) serves different audio
per request.** Megaphone, Art19, Acast, Spreaker and Libsyn stitch ads by geography
and time, so an ad's time range in a file the *server* fetched does not line up with
the file the *device* downloaded, and feed-published transcript timestamps drift by
the inserted ads' length. Any ad-range detection has to run against the exact bytes
the device plays.

Recommendation, in order:

1. **Skip sponsor chapters (small, now).** A per-show/global "Skip sponsor chapters"
   toggle; heuristic on chapter titles (`ad`, `ads`, `sponsor`, `promo`, `advert`,
   `commercial`, `break`) plus "chapter has a URL and is < 3 min". Chapter timestamps
   are authored against the host's canonical file and *are* shifted by DAI on some
   hosts, so gate it per show and make it easy to turn off. Zero server cost.
2. **On-device transcript classification for downloads (the real feature).** For a
   downloaded episode, transcribe on-device (iOS 26 `SpeechAnalyzer`, or
   `SFSpeechRecognizer` with on-device recognition on iOS 17–18), send the timed text
   to a new API endpoint that classifies ad segments with an LLM and returns
   `[(start, end, sponsor)]`, store them on the download record, and skip them via
   the edit-list mechanism from finding 5. Runs against the exact file, so DAI is not
   a problem. Cost is one classification call per downloaded episode, text only.
   Feed transcripts can seed this for feeds that publish them, with the timestamps
   re-aligned against the on-device transcript.
3. **Cross-episode repeat detection (later, optional).** Fingerprint the first/last
   few minutes and any loudness-shifted segment of each downloaded episode of a show;
   segments that recur across episodes are ads. Catches host-read ads that #2 might
   miss and needs no transcript, but it is a research project.

## Shipped with this document

- `AudioPlayer.swift`: `.spectral` pitch algorithm; capped silence-skip rate; rewind
  to the resume point after a silence skip; `silenceTimeSaved` pulled out as a pure
  function.
- `SmartSpeedProcessor.swift`: `silenceSkipRate(forPlaybackSpeed:)`; resume
  `itemTime` on `onSilenceStateChanged`; per-buffer `peakLimitedGain`; `softLimit`
  soft-knee limiter; attack/release smoothing with a unity floor; gain hold through
  silence; `boostTargetLevel` 0.35 → 0.2.
- `DownloadManager.swift`: signature / Content-Type / URL extension resolution;
  non-2xx and web-page payloads fail the download from the completion callback.
- Tests: `SmartSpeedProcessorTests` (limiter, skip-rate cap, peak clamp),
  `SmartSpeedProcessorGainStageTests`, `AudioPlayerTests` (spectral, rewind decision,
  capped time-saved), `DownloadManagerTests` (HTML and 403 rejection),
  `DownloadFileTypeDetectionTests`.
- `tools/audio/`: the render and pause-measurement harness.

## Roadmap (each wants its own issue)

1. **Splice-based Trim Silence for downloads** — analyze-ahead silence map +
   `AVMutableComposition` edit list + source/composition time map (finding 5).
2. **Skip sponsor chapters** — toggle + title heuristic (finding 7, step 1).
3. **On-device ad detection for downloads** — on-device transcription + API
   classification endpoint + skip ranges through the edit list (finding 7, step 2).
4. **Measure the rate-change latency and the rewind on device** — log the gap between
   the tap's resume `itemTime` and the output position when the restore lands, and
   confirm the zero-tolerance seek is inaudible on both local files and streams.
5. **Play-time fallback for a bad local file** — observe the primary `AVPlayerItem`'s
   status; on `.failed` for a `file://` URL, mark the download record failed and
   re-issue `play()` with the stream URL. Download-time validation (finding 4) is a
   net for new downloads only; this covers files downloaded under the old rule and
   formats AVFoundation cannot decode at all.
6. **Store the enclosure MIME type** in `Episode` and warn on Ogg/Opus enclosures
   before downloading (finding 4).
7. **Listen test the spectral switch on real episodes** at 1.2x–1.5x, where
   `.timeDomain` was fine and spectral's transient softening is the only trade-off;
   if it is noticeable, the fallback is `.timeDomain` ≤ 1.5x and `.spectral` above
   (it also saves some CPU over a long session).
