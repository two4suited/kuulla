# Screenshot captions

Baked into the `screenshots/6.9/` frames by `compose-screenshots.mjs`.

| # | Frame | Caption (keyword in **lime**) |
|---|-------|-------------------------------|
| 01 | Library | Your shows, **synced** to the second |
| 02 | Now Playing | **Pause here.** Resume there. |
| 03 | Show detail | Every episode, **filtered** your way |
| 04 | Subscriptions | Follow shows. **Keep** your place. |

Spare captions if the set grows:

- Transcript — Read along, **tap** to jump
- CarPlay — Your queue, **on the dash**
- Search — Find the show, **not the noise**

## Design spec

- **Canvas** 1320×2868, `#050505` (Void).
- **Caption band** top 560px, opaque Void — covers the status bar.
- **Type** Space Grotesk 700, 108px, `letter-spacing: -2`, two lines max, left-aligned
  with a 96px margin. One word (or the lead phrase) in lime `#C6F24E`; the rest bone
  `#F4F4F2`.
- **Accent** a 132×10px lime rule below the text, `rx` 5.
- **Screenshot** placed full-width, bottom-aligned, so the tab bar stays visible and the
  band sits over the (hidden) status bar.
- One lime element per frame (the keyword). No other decoration.
