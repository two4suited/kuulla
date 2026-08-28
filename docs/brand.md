# Kuulla brand & design system — "Signal"

The canonical visual system for Kuulla across web and iOS. Every Marketing-milestone
surface (app icon, web re-skin, iOS theme layer, landing site, App Store assets) builds
against this document.

Direction chosen in [#343](https://github.com/sheridan-apps/kuulla/issues/343);
foundations tracked in [#344](https://github.com/sheridan-apps/kuulla/issues/344).

---

## 1. Direction

**True-black, monospace-tagged, sync as the hero.** Every timestamp, LUFS value, and
device-handoff marker is *shown* rather than hidden. The interface is sharp and precise;
the lime accent is a real signal — it appears only where something is live, fresh, or the
primary action, never as decoration.

The look is dark-first. A light counterpart exists and is fully supported, but the app
ships dark and the marketing material is dark.

---

## 2. Brand voice

- **Tagline: "Podcasts, edited like radio."**
  Grafted from the Broadcast pitch. It rides with the wordmark in nav and footer lockups
  and is the App Store subtitle. Set in Space Grotesk, sentence case, always with the
  period. It says *what Kuulla is* — curated, editorial.
- **Proof point: "Pause here. Resume there."**
  The sync story. Used as the landing-page headline and echoed in-product wherever the
  handoff is visible. It is the evidence, not the identity — keep it distinct from the
  tagline; never blend the two into one line.
- **Everywhere else:** plain, technical, lowercase-comfortable. Show the number
  (`12:04`, `-14 LUFS`, `synced 2s ago`) instead of describing it. No exclamation marks
  outside the two lines above.

---

## 3. Colour

### 3.1 Dark (default)

| Role | Token | Hex | Usage |
|------|-------|-----|-------|
| Void | `--k-bg` | `#050505` | page background (true black, OLED) |
| Panel | `--k-surface` | `#111111` | cards, nav bar, sheets |
| Raised | `--k-surface-2` | `#181818` | inputs, menus, popovers |
| Raised+ | `--k-surface-3` | `#1F1F1F` | pressed / nested surfaces |
| Line | `--k-border` | `#1C1C1C` | 1px hairlines |
| Text | `--k-text` | `#F4F4F2` | primary text ("bone", not pure white) |
| Text muted | `--k-text-muted` | `#8A8F98` | metadata, secondary labels |
| Text faint | `--k-text-faint` | `#5A5F68` | disabled, decorative, large-only |
| **Signal** | `--k-accent` | `#C6F24E` | primary action, playing state, sync-fresh, focus |
| Signal hover | `--k-accent-hover` | `#D4FF6B` | hover on lime fills |
| Signal active | `--k-accent-active` | `#A9D63C` | pressed lime fills |
| Signal soft | `--k-accent-soft` | `rgba(198,242,78,.14)` | active-nav bg, focus ring, `::selection` |
| Signal ink | `--k-accent-ink` | `#C6F24E` | lime used *as text* (links) — see §3.3 |
| Signal ink hover | `--k-accent-ink-hover` | `#D4FF6B` | link hover |
| On-lime | `--k-accent-contrast` | `#0A0A0A` | text/icons on a lime fill |
| Success | `--k-success` | `#4ADE80` | download complete, healthy sync |
| Danger | `--k-danger` | `#F2555A` | errors, destructive actions |
| Info | `--k-info` | `#5AC8E8` | neutral notices |
| Warning | `--k-warning` | `#E8B84A` | degraded state, offline |

Semantic colours (`success` / `danger` / `info` / `warning`) are **separate from the
accent** and never substitute for it. Each has a matching `-soft` token for tinted
backgrounds.

### 3.2 Light (counterpart)

| Role | Token | Hex |
|------|-------|-----|
| Background | `--k-bg` | `#F4F4F2` |
| Surface | `--k-surface` | `#FFFFFF` |
| Raised | `--k-surface-2` | `#ECECEA` |
| Raised+ | `--k-surface-3` | `#E2E2DF` |
| Line | `--k-border` | `#D8D8D4` |
| Text | `--k-text` | `#0A0A0A` |
| Text muted | `--k-text-muted` | `#5A5F68` |
| Text faint | `--k-text-faint` | `#8A8F98` |
| Signal (fills) | `--k-accent` | `#C6F24E` — unchanged; only ever a fill in light mode |
| Signal ink | `--k-accent-ink` | `#4A6410` — darkened so lime text passes AA |
| Signal ink hover | `--k-accent-ink-hover` | `#3A4F0C` |
| Signal soft | `--k-accent-soft` | `rgba(150,190,50,.24)` |

### 3.3 The lime-as-text rule

Lime `#C6F24E` on the light background is ~1.2:1 — unreadable. So:

- **Fills** (buttons, scrubber, badges, the playing indicator) use `--k-accent` in both
  themes, with `--k-accent-contrast` (`#0A0A0A`) for any text on top.
- **Text** (links, `.btn-link`, active-nav label) uses `--k-accent-ink`, which is lime on
  dark and dark olive-lime on light.

Never set `color: var(--k-accent)` directly. Use `--k-accent-ink`.

### 3.4 Contrast (WCAG 2.1, approximate — re-verify with a checker in review)

| Pair | Ratio | Verdict |
|------|-------|---------|
| `#F4F4F2` on `#050505` | ~19.8 : 1 | AAA |
| `#8A8F98` on `#050505` | ~6.3 : 1 | AA (normal text) |
| `#5A5F68` on `#050505` | ~3.2 : 1 | large text / non-text only |
| `#C6F24E` on `#050505` | ~15.8 : 1 | AAA |
| `#0A0A0A` on `#C6F24E` | ~15.7 : 1 | AAA (button text) |
| `#0A0A0A` on `#F4F4F2` | ~18 : 1 | AAA |
| `#5A5F68` on `#F4F4F2` | ~5.8 : 1 | AA |
| `#4A6410` on `#F4F4F2` | ~6.1 : 1 | AA (link text, light) |

`--k-text-faint` is intentionally sub-AA — it is only for disabled controls, decorative
rules, and text ≥ 24px (or ≥ 19px bold).

---

## 4. Typography

| Role | Face | Weights | Usage |
|------|------|---------|-------|
| Display | **Space Grotesk** | 500, 700 | `h1`–`h3`, wordmark, large numerals |
| Body / UI | **Manrope** | 400, 500, 600 | paragraphs, buttons, list rows, form labels |
| Utility | **JetBrains Mono** | 400, 500, 700 | every timestamp, `-14 LUFS`, `synced 2s ago`, durations, episode numbers, keyboard hints |

All three are Google Fonts — no licensing cost. Tokens: `--k-font`, `--k-font-display`,
`--k-font-mono`.

**Rule of thumb:** if it's a number that came from the audio engine or the sync engine,
it's set in JetBrains Mono.

### 4.1 Type scale

| Step | Size | Line-height | Typical use |
|------|------|-------------|-------------|
| `xs` | 12px | 1.4 | mono metadata, captions |
| `sm` | 13px | 1.5 | secondary text, dense lists |
| `base` | 15px | 1.6 | body |
| `md` | 18px | 1.4 | list titles, lead paragraph |
| `lg` | 22px | 1.3 | section headings (`h3`) |
| `xl` | 28px | 1.2 | page headings (`h2`) |
| `2xl` | 40px | 1.1 | hero / `h1` |

Headings: weight 700, `letter-spacing: -0.015em`, `text-wrap: balance`.
Body: weight 400, measure ≤ 68 characters.
Uppercase mono labels: `letter-spacing: 0.08em`.

---

## 5. Spacing

4px base unit. Steps in use: **4 · 8 · 12 · 16 · 24 · 32 · 48 · 64**.
Lay groups out with flex/grid `gap`, not stacked margins.

---

## 6. Radius

Signal is sharp — a deliberate reduction from the previous system's `0.5–1.125rem`.

| Token | Value | Use |
|-------|-------|-----|
| `--k-radius-sm` | `4px` | inputs, badges, chips, segmented (grouped) buttons |
| `--k-radius` | `6px` | cards, list groups, alerts |
| `--k-radius-lg` | `10px` | standalone buttons, modals, sheets, hero panels |
| `--k-radius-pill` | `999px` | pills, the sync-fresh dot, avatars |

Standalone buttons are softly rounded (`--k-radius-lg`) — like a normal media-player
button, not blocky. The sharper radii stay on the surfaces around them (cards, inputs,
chips); grouped/segmented buttons stay sharp so the segments read as one control.

---

## 7. Motion

Fast and precise. No bounce, no overshoot.

- Hover / toggle / focus transitions: **120–160ms**, `ease-out`.
- Page and list transitions: **200ms** max.
- The **one** ambient animation: a slow pulse on the lime "sync-fresh" dot
  (~2s, opacity 0.5 → 1 → 0.5).
- Always gate non-essential motion behind `@media (prefers-reduced-motion: reduce)` on
  web and `UIAccessibility.isReduceMotionEnabled` / `.accessibilityReduceMotion` on iOS.

---

## 8. Iconography

- Line icons, **1.5px** stroke, near-square proportions, 2px corner radius on joins.
- No filled glyphs except the **play triangle** (which is solid, in `--k-accent` when it
  denotes the currently-playing item).
- The **sync-graph motif** — nodes on a waveform polyline, the shape of the app icon
  ([#345](https://github.com/sheridan-apps/kuulla/issues/345)) — is the recurring brand
  mark. Use it for empty states, loading states, and the marketing site. Keep it out of
  functional UI chrome such as buttons and controls.
- **Icon sources:** `docs/brand/icon-master.svg` (4-node signal transient, 1024,
  App Store / iOS / apple-touch), `docs/brand/icon-small.svg` (3-node reduction, used for
  `favicon.svg`/`favicon.png` and the nav wordmark mark), `docs/brand/icon-tinted.svg`
  (grayscale, iOS 18 tinted appearance). Regenerate the PNGs from these — never hand-edit
  a raster.

---

## 9. Using the accent — dos and don'ts

**Do use lime for:**

- the primary button on a view (one per view)
- the currently-playing episode indicator and the play triangle
- the scrubber's elapsed fill
- the "sync-fresh" dot and `synced Ns ago` when the last sync is recent
- keyboard focus rings (`--k-accent-soft`)
- the active navigation item's label and background tint

**Don't use lime for:**

- body text, headings, or icons that aren't a primary action
- decorative dividers, backgrounds, or large fills
- more than one call-to-action in the same viewport
- error, warning, success, or info states — those have their own semantic colours
- hover states on non-primary controls (use surface / border shifts instead)

If a second thing on screen is lime, one of them is wrong.

---

## 10. Token reference — web ↔ iOS

The iOS theme layer ([#347](https://github.com/sheridan-apps/kuulla/issues/347)) mirrors
these 1:1 as a colour asset catalog plus Swift constants. Colour assets carry **Any**
(= light) and **Dark** appearances.

| CSS variable | iOS asset name | Swift accessor | Light | Dark |
|--------------|----------------|----------------|-------|------|
| `--k-bg` | `Background` | `KuullaColor.background` | `#F4F4F2` | `#050505` |
| `--k-surface` | `Surface` | `KuullaColor.surface` | `#FFFFFF` | `#111111` |
| `--k-surface-2` | `SurfaceRaised` | `KuullaColor.surfaceRaised` | `#ECECEA` | `#181818` |
| `--k-surface-3` | `SurfacePressed` | `KuullaColor.surfacePressed` | `#E2E2DF` | `#1F1F1F` |
| `--k-border` | `Line` | `KuullaColor.line` | `#D8D8D4` | `#1C1C1C` |
| `--k-text` | `TextPrimary` | `KuullaColor.textPrimary` | `#0A0A0A` | `#F4F4F2` |
| `--k-text-muted` | `TextMuted` | `KuullaColor.textMuted` | `#5A5F68` | `#8A8F98` |
| `--k-text-faint` | `TextFaint` | `KuullaColor.textFaint` | `#8A8F98` | `#5A5F68` |
| `--k-accent` | `Signal` | `KuullaColor.signal` | `#C6F24E` | `#C6F24E` |
| `--k-accent-ink` | `SignalInk` | `KuullaColor.signalInk` | `#4A6410` | `#C6F24E` |
| `--k-accent-soft` | `SignalSoft` | `KuullaColor.signalSoft` | `rgba(150,190,50,.24)` | `rgba(198,242,78,.14)` |
| `--k-accent-contrast` | `OnSignal` | `KuullaColor.onSignal` | `#0A0A0A` | `#0A0A0A` |
| `--k-success` | `Success` | `KuullaColor.success` | `#3AA66F` | `#4ADE80` |
| `--k-danger` | `Danger` | `KuullaColor.danger` | `#D83A3F` | `#F2555A` |
| `--k-info` | `Info` | `KuullaColor.info` | `#2F9FC4` | `#5AC8E8` |
| `--k-warning` | `Warning` | `KuullaColor.warning` | `#C98A1F` | `#E8B84A` |

Radius: `Radius.sm = 4`, `Radius.md = 6`, `Radius.lg = 10` (points).
Spacing: `Space.xs = 4 … Space.xxl = 64`.
Fonts on iOS: bundle Space Grotesk, Manrope, JetBrains Mono; expose `.kuullaTitle`,
`.kuullaBody`, `.kuullaMono` scaled to the §4.1 steps with Dynamic Type support.

---

## 11. Where the tokens live

- **Web:** `src/Kuulla.Web/wwwroot/app.css` `:root` / `[data-bs-theme="…"]` blocks.
  Fonts loaded in `src/Kuulla.Web/Components/App.razor`.
- **iOS:** colour asset catalog + `Theme.swift` / `Typography.swift`
  ([#347](https://github.com/sheridan-apps/kuulla/issues/347), not yet created).
- **Marketing site:** reuses `app.css` tokens
  ([#348](https://github.com/sheridan-apps/kuulla/issues/348)).
