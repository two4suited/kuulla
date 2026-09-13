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

## Real-device crash fixed (2026-09-11)

The first real-head-unit connection crashed immediately on connect, 100% reproducible
(`_deliverInterfaceControllerToDelegate` raising `NSException` before `CarPlaySceneDelegate`'s
`didConnect` ever ran — confirmed from on-device crash logs pulled via
`xcrun devicectl device info files --domain-type systemCrashLogs`). Cause: `Info.plist`'s
`CPTemplateApplicationSceneSessionRoleApplication` entry had `UISceneConfigurationName` but no
`UISceneClassName`, which Apple's CarPlay templates require to be explicitly
`CPTemplateApplicationScene`. Fixed by adding that key; verified crash-free on a real car after
the fix.

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

### Troubleshooting the CarPlay Simulator

Confirmed via `Simulator` app + guest OS log inspection (2026-09-12):

- **Menu click does nothing (no window at all).** Usually a stale external-display capture
  session left behind by another tool that attached to the Simulator's screen (e.g. a crashed
  screen-mirroring/automation tool). Symptom in the host log
  (`/usr/bin/log show --process Simulator --style compact`, filter for `ROCKit`/`sidecar`): repeated
  `Failed to try resuming capture session` followed by, right as you click CarPlay, `ROCKit Soft
  Assertion Failure ... Invalid impersonatable proxy UUID specified` for
  `SimDisplayIOSurfaceRenderable`. Fix: fully kill Simulator (`kill -9 <pid>`, found via
  `ps -axo pid,comm | grep -i 'MacOS/Simulator$'`), `xcrun simctl shutdown all`, then reboot the
  device and relaunch Simulator fresh.
- **Menu click registers (`perform action for menu item` in the host log) but still no window,
  or the window opens with only the 4 built-in icons (Phone/Maps/Music/Now Playing).** Check the
  host log for `unable to find target mode matching size: (800.0, 480.0), scale: 2.0` right after
  the click — that's CarPlay's virtual-display resolution negotiation failing for this specific
  simulated device/runtime pairing. It's device-specific, not a Kuulla bug: switch to a different
  simulated device (e.g. iPhone 17 Pro Max instead of iPhone 17 Pro) and retry.
- **CarPlay window opens fine but Kuulla's icon never appears.** The CarPlay window snapshots
  installed apps at connect time. If Kuulla was installed/relaunched *after* CarPlay was already
  open, toggle it off and back on (I/O → External Displays → CarPlay, click twice) to force
  re-enumeration, rather than assuming the app is broken.
- **The `com.apple.developer.carplay-audio` entitlement is never present on a Simulator build,
  confirmed with `codesign -d --entitlements - --xml <path>/Kuulla.app`** — it comes back an empty
  `<dict/>` even with `-allowProvisioningUpdates` and the real team's Apple Development identity,
  because Xcode always ad-hoc-signs Simulator builds (`TeamIdentifier=not set`) regardless of the
  scheme's signing settings. This is expected, not a regression — don't chase it. It's also why
  entitlement state is irrelevant to whether the app shows up on the CarPlay Simulator's home
  screen at all.
- **Useful log commands** — host Simulator.app process:
  `/usr/bin/log show --last 5m --predicate 'process == "Simulator"' --style compact`; the *guest*
  iOS inside a given simulator (SpringBoard, installd, runningboardd — this is where you see
  Kuulla's actual scene/install lifecycle):
  `xcrun simctl spawn <udid> log show --last 10m --predicate 'eventMessage contains[c] "kuulla"' --style compact`.

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
