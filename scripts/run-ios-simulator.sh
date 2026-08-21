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
SIMULATOR_NAME="${KUULLA_SIMULATOR_NAME:-iPhone 16}"

echo "run-ios-simulator.sh: building for '$SIMULATOR_NAME' with KUULLA_API_BASE_URL=$KUULLA_API_BASE_URL"

xcodebuild build \
  -project "$IOS_DIR/Kuulla.xcodeproj" \
  -scheme Kuulla \
  -destination "platform=iOS Simulator,name=$SIMULATOR_NAME" \
  CODE_SIGNING_ALLOWED=NO

APP_PATH=$(xcodebuild -project "$IOS_DIR/Kuulla.xcodeproj" -scheme Kuulla \
  -destination "platform=iOS Simulator,name=$SIMULATOR_NAME" \
  -showBuildSettings 2>/dev/null \
  | awk -F ' = ' '/ BUILT_PRODUCTS_DIR / { print $2; exit }')
APP_PATH="$APP_PATH/Kuulla.app"

# Uses --json + jq for an exact device-name match (avoiding e.g. "iPhone 16" matching
# "iPhone 16 Pro" on a substring), preferring the newest iOS runtime when the same
# simulator name exists under multiple installed runtimes.
UDID=$(xcrun simctl list devices available --json \
  | jq -r --arg name "$SIMULATOR_NAME" '
      .devices
      | to_entries
      | map(select(.key | test("com\\.apple\\.CoreSimulator\\.SimRuntime\\.iOS")))
      | sort_by(.key)
      | map(.value[] | select(.name == $name))
      | last
      | .udid // empty
    ')

if [[ -z "$UDID" ]]; then
  echo "run-ios-simulator.sh: no Simulator found named '$SIMULATOR_NAME'" >&2
  exit 1
fi

xcrun simctl boot "$UDID" 2>/dev/null || true
open -a Simulator --args -CurrentDeviceUDID "$UDID"
xcrun simctl bootstatus "$UDID" -b

xcrun simctl install "$UDID" "$APP_PATH"

# simctl only forwards launch-environment variables prefixed with SIMCTL_CHILD_
# that are present in *its own* calling environment; that's how the Simulator
# (an OS process, not a container Aspire can inject env into directly)
# receives the API's URL.
export SIMCTL_CHILD_KUULLA_API_BASE_URL="$KUULLA_API_BASE_URL"
exec xcrun simctl launch --console-pty "$UDID" "$BUNDLE_ID"
