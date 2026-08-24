# SmartSpeed spike: MTAudioProcessingTap vs AVAudioEngine

Spiked in [#199](https://github.com/sheridan-apps/kuulla/issues/199) ahead of
[#202](https://github.com/sheridan-apps/kuulla/issues/202) ("SmartSpeed" — Overcast's
name for the combined silence-trim + volume-boost toggle, per
[#200](https://github.com/sheridan-apps/kuulla/issues/200)). `AudioPlayer` today
(`ios/Kuulla/Kuulla/AudioPlayer.swift`) is a thin wrapper around `AVPlayer`, and
playback speed (#194-198) already ships as `AVPlayer.rate` + `.timeDomain` pitch
correction — neither silence detection nor gain processing has any equivalent on
`AVPlayer` today, so both options below start from the same gap.

## Option A: `MTAudioProcessingTap` on the current `AVPlayer`

Attach an `MTAudioProcessingTap` to the `AVPlayerItem`'s audio mix
(`AVMutableAudioMixInputParameters.audioTapProcessor`). The tap's process callback runs
synchronously on an internal real-time audio thread, just before rendering, and sees
only audio that `AVPlayer` has already decoded and buffered — never audio still in
flight over the network.

- **Volume boost**: apply gain directly to the interleaved/planar sample buffer inside
  the callback — a soft-knee compressor/limiter (attack/release smoothing to avoid
  pumping, ceiling near 0 dBFS) written as plain sample-loop DSP. No need to host a
  separate `AudioUnit` (e.g. `AUDynamicsProcessor`) inside the tap; that's possible but
  adds AudioComponent-hosting complexity this doesn't need for a single gain stage.
- **Silence trim**: compute rolling RMS per callback; once a below-threshold run
  exceeds a minimum duration (avoids trimming mid-word pauses), the callback can't seek
  the player itself — a tap runs off-main and mid-render — so it hands the detected
  window to `AudioPlayer` via a thread-safe callback, which dispatches an `async` seek
  on the main queue to skip past it. Because the tap only sees already-buffered audio,
  the skip target is always inside material `AVPlayer` already has; it never seeks into
  unbuffered network audio and can't trigger a stall.
- Keeps `AVPlayer` as the playback engine: streaming, progressive download playback,
  buffering/stall handling, background audio session, and remote-command-center/lock-
  screen integration are all unchanged. Playback speed (#194-198) needs no changes.
- Downside: coarser control than a full engine — trimming is "seek past a detected
  silent run," not sample-accurate splicing, and gain is a single hand-rolled DSP stage
  rather than a composable AudioUnit graph. Both are sufficient for this feature's
  bar (tighten pacing, normalize loud/quiet segments) and match what the issue asks for.

## Option B: migrate to `AVAudioEngine`

Replace `AVPlayer` with `AVAudioPlayerNode` → `AVAudioUnitTimePitch` (subsuming #194-198's
speed/pitch control) → a dynamics-processor `AVAudioUnitEffect` → the engine's main
mixer. This gives silence trim and volume boost as first-class, composable nodes and a
tap on the mixer for analysis, with no MTAudioProcessingTap plumbing.

The blocker is upstream of any of that: `AVAudioPlayerNode` schedules `AVAudioPCMBuffer`s
or plays from a local `AVAudioFile` — it has no progressive-network-streaming
equivalent to `AVPlayer(url:)`. Kuulla plays both downloaded local files and remote
episode URLs directly (`AudioPlayer.play(url:)`, `ios/Kuulla/Kuulla/AudioPlayer.swift:105`);
supporting the remote case on `AVAudioEngine` means standing up a custom
decode-and-buffer pipeline (e.g. `AVAssetReader` feeding the engine in manual-rendering
mode) to replace what `AVPlayer` currently does for free. On top of that, background
audio session handling, remote-command-center integration, and interruption handling
(currently implicit via `AVPlayer` + the `.playback`/`.spokenAudio` session) all need to
be re-verified or rebuilt against the engine. This is a full player-layer rewrite, not
an additive change.

## Recommendation

**Option A — `MTAudioProcessingTap` on the existing `AVPlayer`.** It delivers both
halves of SmartSpeed without touching streaming, downloads, background audio, or the
already-shipped speed/pitch control, and is scoped in line with the rest of this
milestone's issues. Rough sizing: **medium**, comparable to the playback-speed
milestone (#194-198) — a new tap-processor component (prepare/process/unprepare
callbacks), the RMS-threshold silence detector with hysteresis, the gain/compressor
DSP, and wiring the detected-silence-window callback into `AudioPlayer`'s seek path.

Option B (`AVAudioEngine`) is **not** recommended for this milestone: the streaming
pipeline it would need to replace is a large, separate migration whose cost isn't
justified by this feature alone. If a future need (e.g. gapless playback, richer DSP
chains) makes an engine migration worthwhile on its own merits, SmartSpeed's tap-based
DSP logic (RMS detection, gain stage) is portable to an `AVAudioEngine` tap/node at that
point — Option A doesn't paint the app into a corner.

This does **not** reshape #200-#204: DB/API/UI scoping stays as-is; only #202
("Implement silence trimming & volume boost") is scoped by this recommendation, to
build the `MTAudioProcessingTap`-based approach.
