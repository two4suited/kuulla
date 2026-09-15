# Measuring silence-skip rate-restore latency (#780)

`#776` capped the silence-skip rate at 6x and added a rewind-to-`itemTime` seek for
when the rate restore lands more than `silenceRewindThreshold` (50 ms) late. Both the
100–300 ms latency figure and the 50 ms threshold were reasoned estimates, not
measurements. This is how to collect the real numbers on a physical device and decide
whether `SmartSpeedProcessor.maxSilenceSkipRate` / `AudioPlayer.silenceRewindThreshold`
should move.

## What's instrumented

`AudioPlayer.wireUpFreshlyStartedPlayer`'s `onSilenceStateChanged` handler (the same
closure that restores `player.rate` and decides whether to rewind) now logs, in DEBUG
builds only, every time a silence run ends:

```
gap=0.187s speed=2.0x isLocalFile=true rewinding=true
```

- `gap` — `player.currentTime()` minus the tap's `itemTime` at the moment the rate
  restore lands. This *is* the rate-restore latency the design estimated at 100–300 ms.
- `speed` — the session's configured playback speed (1x/2x/3x) at the time.
- `isLocalFile` — downloaded file vs. streamed URL.
- `rewinding` — whether `shouldRewindAfterSilence` decided to seek back.

Logged via `os.Logger(subsystem: "com.kuulla.app", category: "SmartSpeed")`
(`AudioPlayer.silenceRestoreLogger`).

## Collecting the numbers, on-device

1. Build and install a Debug build on a physical device — see "Run on a physical
   device" in the root [CLAUDE.md](../CLAUDE.md).
2. Open Console.app on the Mac, select the device, and filter on subsystem
   `com.kuulla.app` / category `SmartSpeed` (or attach the Xcode debug console while
   running from Xcode).
3. Play an episode with a show/global setting that enables Trim Silence or SmartSpeed
   (Settings → the show or global audio settings), with plenty of natural pauses —
   an interview or a scripted show with sentence breaks works better than music-bed
   content.
4. Repeat at 1x, 2x, and 3x, for both a downloaded (local file) episode and a streamed
   one, letting several silence runs pass at each combination. Note the `gap` values.
5. While each run plays, listen specifically at the moment sound resumes after a pause,
   for:
   - An audible click or discontinuity from the `seek(to:toleranceBefore:.zero,
     toleranceAfter:.zero)` rewind (only fires when `rewinding=true`).
   - Any re-buffering / stutter from the zero-tolerance seek, particularly on streams
     where the exact frame may not be locally cached.

## Deciding from the numbers

- If `gap` consistently falls inside 100–300 ms, the existing constants are already
  right and this issue can close as "confirmed, no change."
- If `gap` is consistently higher (e.g. streams warming up a new buffer position after
  the rate change), consider whether `maxSilenceSkipRate` should come down — a lower
  cap means less audio was skipped and the restore has less pipeline lag to hide.
- If the rewind seek is audible as a click or causes a stream to re-buffer, either
  raise `silenceRewindThreshold` (accept losing a bit more audio to avoid the seek) or
  look at a non-zero tolerance seek as a middle ground.
- If `gap` is small and consistent enough that the rewind rarely fires at all, that's
  also useful signal — it means the estimate was conservative and the constants have
  headroom.

Record the observed numbers and the resulting decision back on #780 (and update the
constants' doc comments in `SmartSpeedProcessor.swift` / `AudioPlayer.swift` if they
move).
