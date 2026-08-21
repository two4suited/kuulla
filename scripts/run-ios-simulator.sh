#!/usr/bin/env bash
# Builds Kuulla for the iOS Simulator, boots a Simulator, installs the app, and
# launches it with the API's Aspire-resolved base URL injected as an env var.
#
# Invoked by AppHost.cs as an executable resource ("ios-simulator") so the app
# can reach the API without manually copying its random per-run port into the
# Xcode scheme (see issue #50's KUULLA_API_BASE_URL workaround, and #51).
#
# Requires KUULLA_API_BASE_URL to be set in the environment (Aspire sets this
# from the api resource's resolved endpoint).
set -euo pipefail

if [[ -z "${KUULLA_API_BASE_URL:-}" ]]; then
  echo "run-ios-simulator.sh: KUULLA_API_BASE_URL is not set" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IOS_DIR="$REPO_ROOT/ios/Kuulla"
BUNDLE_ID="com.kuulla.app"

# Discovers an installed iPhone Simulator via python3 (already a build-ios CI dependency,
# .github/workflows/pr.yml) rather than assuming a specific model: pinning e.g. "iPhone 16"
# breaks the moment Xcode's bundled simulator lineup moves on and that model disappears.
# KUULLA_SIMULATOR_NAME can still force an exact device name when one is needed.
# When more than one installed runtime has a matching device, the newest iOS runtime wins.
IFS=$'\t' read -r UDID SIMULATOR_NAME < <(
  xcrun simctl list devices available -j | python3 -c "
import json, os, re, sys

data = json.load(sys.stdin)['devices']
wanted = os.environ.get('KUULLA_SIMULATOR_NAME')


def runtime_version(runtime_id):
    match = re.search(r'iOS-(\d+)-(\d+)', runtime_id)
    return tuple(int(part) for part in match.groups()) if match else (0, 0)


candidates = []
for runtime_id, devices in data.items():
    if 'iOS' not in runtime_id:
        continue
    for device in devices:
        if wanted:
            if device['name'] == wanted:
                candidates.append((runtime_id, device))
        elif device['name'].startswith('iPhone'):
            candidates.append((runtime_id, device))

if not candidates:
    sys.exit(1)

_, chosen = max(candidates, key=lambda c: runtime_version(c[0]))
print(chosen['udid'], chosen['name'], sep='\t')
"
) || {
  echo "run-ios-simulator.sh: no Simulator found${KUULLA_SIMULATOR_NAME:+ named '$KUULLA_SIMULATOR_NAME'}" >&2
  exit 1
}

echo "run-ios-simulator.sh: building for '$SIMULATOR_NAME' with KUULLA_API_BASE_URL=$KUULLA_API_BASE_URL"

xcodebuild build \
  -project "$IOS_DIR/Kuulla.xcodeproj" \
  -scheme Kuulla \
  -destination "platform=iOS Simulator,id=$UDID" \
  CODE_SIGNING_ALLOWED=NO

APP_PATH=$(xcodebuild -project "$IOS_DIR/Kuulla.xcodeproj" -scheme Kuulla \
  -destination "platform=iOS Simulator,id=$UDID" \
  -showBuildSettings 2>/dev/null \
  | awk -F ' = ' '/ BUILT_PRODUCTS_DIR / { print $2; exit }')
APP_PATH="$APP_PATH/Kuulla.app"

xcrun simctl boot "$UDID" 2>/dev/null || true
open -a Simulator --args -CurrentDeviceUDID "$UDID"
xcrun simctl bootstatus "$UDID" -b

xcrun simctl install "$UDID" "$APP_PATH"

# simctl only forwards launch-environment variables prefixed with SIMCTL_CHILD_
# that are present in *its own* calling environment; that's how the Simulator
# (an OS process, not a container Aspire can inject env into directly)
# receives the API's URL.
# --terminate-running-process: restarting this explicit-start resource re-runs this script
# while the app may still be running from a previous launch; simctl launch fails without it.
export SIMCTL_CHILD_KUULLA_API_BASE_URL="$KUULLA_API_BASE_URL"
exec xcrun simctl launch --console-pty --terminate-running-process "$UDID" "$BUNDLE_ID"
