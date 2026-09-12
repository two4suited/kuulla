# CarPlay entitlement runbook

How the `com.apple.developer.carplay-audio` entitlement got unblocked, and how to verify the
CarPlay code end to end. Tracks [#522](https://github.com/two4suited/kuulla/issues/522).

## Current state

All the CarPlay code from the "CarPlay Support" milestone (#115–#118) is merged and wired:

| Piece | Where | Status |
| --- | --- | --- |
| Template scene → delegate routing | `AppDelegate.application(_:configurationForConnecting:options:)` in `KuullaApp.swift` — returns a `UISceneConfiguration` with `delegateClass = CarPlaySceneDelegate.self` for the `.carTemplateApplication` role | ✅ correct (programmatic wiring; the SwiftUI `App` lifecycle has no Info.plist `UISceneDelegateClassName` hook, so this is the supported path) |
| Scene manifest | `Info.plist` → `UIApplicationSceneManifest` declares `CPTemplateApplicationSceneSessionRoleApplication` with `UISceneConfigurationName = "CarPlay Configuration"`, matching the name the code passes | ✅ |
| Browse UI | `CarPlaySceneDelegate` — subscriptions list → episodes list → Now Playing, reusing `SubscriptionClient` / `PodcastCatalogClient` / `SettingsClient` and the phone's `EpisodeStatus` + `EpisodeDetailView.resolvedPlaybackURL` | ✅ |
| Playback | `AudioPlayer.shared.play(...)`; transport comes from the shared `MPRemoteCommandCenter` targets AudioPlayer already registers (no separate CarPlay playback path) | ✅ |
| Now Playing template | `CPNowPlayingTemplate.shared`, fed by `MPNowPlayingInfoCenter` from `AudioPlayer.updateNowPlayingInfo()` | ✅ |
| Progress persistence | `progressTrackingTask` — 20 s periodic write + mark-played on finish through `episodeSyncEngine`, mirroring `EpisodeDetailView.startProgressTracking()` | ✅ |
| `com.apple.developer.carplay-audio` entitlement | `Kuulla.entitlements` | ✅ approved for team `96VJBK4H9P` and enabled on the `com.kuulla.app` App ID |

### Background

`com.apple.developer.carplay-audio` is a **restricted** entitlement, granted per Apple Developer
team via <https://developer.apple.com/contact/request/carplay>, separately from Developer
Program membership. Team `96VJBK4H9P` requested it and Apple approved it (2026-09-11); the
CarPlay Audio App capability has since been enabled on the `com.kuulla.app` App ID.

Before approval, `CODE_SIGN_STYLE = Automatic` couldn't provision the key, so Xcode dropped it
from signed builds and iOS never launched the `CPTemplateApplicationScene`. That's no longer the
case — a normal on-device build now signs with the entitlement (verified 2026-09-11: a build with
`-allowProvisioningUpdates -allowProvisioningDeviceRegistration` minted a profile carrying
`com.apple.developer.carplay-audio`, confirmed via `codesign -d --entitlements :-`, then installed
and launched on device `Bsphone`).

Simulator and CarPlay Simulator builds still apply no provisioning profile, so the key is a
no-op there; CI (`xcodebuild build ... CODE_SIGNING_ALLOWED=NO`) is unaffected either way.

## Remaining verification

The code and signing are confirmed. What's left is a real-head-unit pass:

1. **Regenerate the provisioning profile** (only needed again if signing state changes):
   ```sh
   cd ios/Kuulla
   xcodebuild build -project Kuulla.xcodeproj -scheme Kuulla \
     -destination 'platform=iOS,id=<device-udid>' \
     -allowProvisioningUpdates -allowProvisioningDeviceRegistration
   ```
   Verify the entitlement is in the binary:
   ```sh
   APP=$(xcodebuild -project Kuulla.xcodeproj -scheme Kuulla -destination 'platform=iOS,id=<device-udid>' -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{d=$2} / FULL_PRODUCT_NAME /{n=$2} END{print d"/"n}')
   codesign -d --entitlements :- "$APP" | grep carplay-audio
   ```
2. **Install and launch** (see CLAUDE.md for the `devicectl` install/launch commands), then
   connect the phone to a car or a CarPlay-capable head unit and check:
   - Kuulla's icon appears on the CarPlay home screen.
   - Tapping it shows the subscriptions list → an episode list → Now Playing.
   - Play/pause/skip from the car's controls drive playback, and Now Playing shows title +
     artwork + elapsed time.
   - Position is still where you left it when you reopen the episode on the phone (the 20 s
     periodic write), and a finished episode is marked played.
3. Once confirmed, close #522.

## Verify without the entitlement: CarPlay Simulator

Xcode's CarPlay Simulator needs **no entitlement** and runs against the iOS Simulator, so the
browse → Now Playing flow can be exercised today.

1. Build & run the `Kuulla` scheme on an iOS Simulator (sign in first — the browse list needs a
   real subscriptions response; `-KuullaAutoTestSignIn` works here too).
2. In the Simulator menu bar: **I/O → External Displays → CarPlay**.
3. A CarPlay head-unit window opens. Kuulla should appear on its home screen. Exercise:
   - subscriptions list renders, sorted case-insensitively by title, with show artwork;
   - empty state ("You haven't subscribed to any shows yet.") when there are no subscriptions;
   - tapping a show pushes its first page of episodes with duration · status detail text;
   - tapping an episode starts playback and pushes `CPNowPlayingTemplate`;
   - re-tapping the playing episode just re-shows Now Playing (no restart);
   - disconnecting CarPlay (close the window) cancels in-flight loads — no crash, no orphaned
     progress writes.
4. Known simulator gaps (not bugs): the CarPlay Simulator's audio session and
   `MPNowPlayingInfoCenter` rendering are less faithful than a real head unit; artwork loading
   over the network can lag the first render (`imageCache` fills on the second visit). Treat a
   real-device pass (step 4 above) as the acceptance gate.

## Implementation audit (2026-09-10)

Reviewed `CarPlaySceneDelegate.swift`, the scene wiring in `KuullaApp.swift`, `Info.plist`, and
the `AudioPlayer` remote-command / Now Playing integration against Apple's CarPlay audio app
requirements. No code changes needed — the entitlement was the only blocker, and it's approved.

Notes for the eventual on-device pass (none blocking, none worth a code change now):

- **`loadImage` retains `CPListItem` across a raw `URLSession.dataTask`.** Works, and the
  `[weak self]` guard means a disconnect won't crash, but a slow image load after disconnect
  still calls `item.setImage` on a detached template. Harmless; could switch to the shared
  image loader if one is added later.
- **`pushEpisodesList` shows only the first page.** Deliberate (commented) — CarPlay favors a
  short glanceable list over "Load more". Fine; revisit only if users report missing episodes.
- **`CPListTemplate` section has no `CPListImageRowItem` / grid.** Plain rows only. Acceptable
  for v1; a future polish item, not a correctness issue.
- **Now Playing buttons** (`CPNowPlayingTemplate` custom buttons for e.g. speed / skip-silence)
  are not configured — the template shows only the system transport controls. #118 scoped
  custom buttons out; leaving as-is.
- The pure helpers (`sortedSubscriptions`, `episodeDetailText`) are unit-tested
  (`CarPlaySceneDelegateTests`); the scene-driven paths aren't (they need a real
  `CPInterfaceController`), which is why the CarPlay Simulator pass above matters.

## References

- `ios/Kuulla/Kuulla/CarPlaySceneDelegate.swift`
- `ios/Kuulla/Kuulla/KuullaApp.swift` (`AppDelegate.application(_:configurationForConnecting:options:)`)
- `ios/Kuulla/Kuulla/Info.plist` (`UIApplicationSceneManifest`)
- `ios/Kuulla/Kuulla/AudioPlayer.swift` (`updateNowPlayingInfo`, `MPRemoteCommandCenter` targets)
- CLAUDE.md → "Run on a physical device"
- Prior work: #115, #116, #117, #118; on-device deploy #119
