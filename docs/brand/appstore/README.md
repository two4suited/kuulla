# App Store listing assets

Creative for Kuulla's first App Store listing, in the **Signal** direction
(`docs/brand.md`). Submission mechanics — signing, upload, App Review — live in the
**App Store Publishing** milestone ([#120](https://github.com/sheridan-apps/kuulla/issues/120)).

## Files → App Store Connect slots

| File | ASC slot |
|------|----------|
| `marketing-icon-1024.png` | App Information → **App Store icon** (1024×1024, no alpha, no rounding) |
| `screenshots/6.9/01-library.png` … `04-subscriptions.png` | App Store → iOS App → **6.9″ Display** screenshots (1320×2868, portrait) |
| `listing.md` | Name, Subtitle, Promotional Text, Description, Keywords, What's New, URLs |
| `preview-video.md` | **App Preview** storyboard (record separately, ≤30s, 1320×2868) |
| `captions.md` | The caption copy baked into each screenshot + the caption design spec |
| `compose-screenshots.mjs` | Regenerates `screenshots/6.9/` from `screenshots/raw/` |

## Device sizes

- **6.9″ (1320×2868)** — the one required iPhone size in App Store Connect today. Delivered.
- **6.5″ / 5.5″** — no longer required when a 6.9″ set is present; ASC will scale the
  6.9″ frames. Add native captures only if a reviewer asks.
- **iPad** — **N/A.** The target is iPhone-only (`TARGETED_DEVICE_FAMILY = 1` in
  `Kuulla.xcodeproj`).

## Regenerating the screenshots

Raw captures were taken on a booted **iPhone 17 Pro Max** simulator (1320×2868)
against a local Aspire stack, using the DEBUG screenshot launch arguments in
`ContentView.swift`:

```sh
DEV="iPhone 17 Pro Max"
BUNDLE=com.kuulla.app
# 1. build + install a Debug build, 2. make sure `aspire run` is up (test-token endpoint), then:
xcrun simctl launch "$DEV" $BUNDLE -KuullaAutoTestSignIn -KuullaInitialTab library
xcrun simctl io "$DEV" screenshot docs/brand/appstore/screenshots/raw/01-library.png

xcrun simctl launch "$DEV" $BUNDLE -KuullaAutoTestSignIn -KuullaInitialShow 394775318
xcrun simctl io "$DEV" screenshot docs/brand/appstore/screenshots/raw/06-showdetail.png

xcrun simctl launch "$DEV" $BUNDLE -KuullaAutoTestSignIn \
  -KuullaInitialEpisode 394775318 fb083c4885f4d2fe412742993eabf09d
xcrun simctl io "$DEV" screenshot docs/brand/appstore/screenshots/raw/05-nowplaying.png
```

Launch arguments (all `#if DEBUG`, ignored in Release):

| Arg | Effect |
|-----|--------|
| `-KuullaAutoTestSignIn` | signs in via the API's `/dev/test-token` — no Google flow, no taps |
| `-KuullaInitialTab <library\|search\|discovery\|subscriptions\|playlists\|settings>` | opening tab |
| `-KuullaInitialShow <showId>` | deep-links to a show detail on launch |
| `-KuullaInitialEpisode <showId> <episodeId>` | deep-links to an episode detail on launch |

Then composite the caption bands:

```sh
node docs/brand/appstore/compose-screenshots.mjs
```

## Notes

- **Search** and **Discover** frames were skipped for v1 — an empty search field and the
  directory's error state (no live iTunes access locally) don't sell anything. Capture
  them on a device with directory access if the set needs to grow.
- Screenshots are from a Signal-themed build (post-[#347](https://github.com/sheridan-apps/kuulla/issues/347)) — no pre-skin UI.
