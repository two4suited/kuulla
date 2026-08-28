# App Preview — storyboard

One 6.9″ App Preview, **≤ 30 seconds**, 1320×2868, portrait, 30fps. No voice-over;
on-screen captions in Space Grotesk (same style as the screenshot bands, `captions.md`).
Record with `xcrun simctl io <device> recordVideo` on the Signal-themed build, then trim.

The single idea: **"Pause here. Resume there."** — one listen, two devices, no seam.

| Time | Shot | On-screen caption | Notes |
|------|------|-------------------|-------|
| 0.0–3.0s | Cold-launch → Library, thumb scrolls the show grid once | *Your shows, synced to the second* | Establish the app. Signal dark, lime tab. |
| 3.0–6.0s | Tap **99% Invisible** → tap the top episode → episode detail | — | Show the mono meta line and the "In Progress" marker landing. |
| 6.0–9.5s | Tap **Play**. Scrubber moves; elapsed time ticks in mono; a chapter mark passes | *Every timestamp, in the open* | Hold on the moving timestamp for ~1s. |
| 9.5–13.0s | **Cut** to a second device mock (iPad-in-frame render or a laptop still) showing the same episode auto-advancing to where the phone left off; a "synced 2s ago" chip appears | *Pause here.* (lime) | The hero beat. The position visibly matches. |
| 13.0–17.0s | Back on the phone: open the same episode, the resume prompt is already answered, transcript is scrolling in step with playback; tap a transcript line, playback jumps | *Resume there.* | Show the transcript follow + tap-to-seek. |
| 17.0–21.0s | Quick CarPlay simulator shot: Now Playing with chapters + queue on the dash | *…and on the dash* | Only if a clean CarPlay capture is available; otherwise cut. |
| 21.0–25.0s | Return to Library; end card fades up: the sync-graph mark, "Kuulla", "Podcasts, edited like radio." | — | End card on Void, Space Grotesk, one lime node pulse. |

**Fallbacks**

- No second real device: use a static laptop/iPad frame (a web-player screenshot from
  [#346](https://github.com/sheridan-apps/kuulla/issues/346)) for the 9.5–13.0s beat and
  animate only the "synced 2s ago" chip.
- No CarPlay capture: drop 17.0–21.0s and give the transcript beat the extra 4s.
- Keep the whole thing under 30s hard — ASC rejects longer.
