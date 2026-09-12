# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Kuulla is a podcast app focused on audio quality and fast syncing. It has a .NET 10 backend, Blazor web frontend, and Swift iOS app. Runs on Azure in production, uses .NET Aspire for local development orchestration.

## Commands

### Run locally (starts all services via Aspire)
```sh
aspire run
```

### Run in background
```sh
aspire start
aspire stop
```

### View running resources
```sh
aspire ps
aspire describe
aspire logs <resource>
```

### Add an Aspire integration
```sh
aspire add <integration>
```

### Build
```sh
dotnet build Kuulla.sln
```

### Test
```sh
dotnet test Kuulla.sln
```

### Run a single test
```sh
dotnet test --filter "FullyQualifiedName~TestClassName.TestMethodName"
```

### iOS (requires Xcode)
```sh
cd ios/Kuulla
xcodebuild build -project Kuulla.xcodeproj -scheme Kuulla -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO
```

### Run on a physical device (for CarPlay / on-device testing — issue #119)

Signing is committed: `DEVELOPMENT_TEAM = 96VJBK4H9P` (Kuulla paid team) with
`CODE_SIGN_STYLE = Automatic`. Requires that team's Apple ID signed into Xcode
(Settings → Accounts) so Xcode can mint the Apple Development certificate.

One-time device setup:
- On the phone: Settings → Privacy & Security → **Developer Mode** on, then reboot.
- First build must register the device with the account — pass both flags below.
  `-allowProvisioningDeviceRegistration` is what adds an unregistered device to the
  team profile (`-allowProvisioningUpdates` alone fails with "isn't registered").

```sh
cd ios/Kuulla
# Find the device id: xcrun xctrace list devices
xcodebuild build -project Kuulla.xcodeproj -scheme Kuulla \
  -destination 'platform=iOS,id=<device-udid>' \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration

APP=$(xcodebuild -project Kuulla.xcodeproj -scheme Kuulla -destination 'platform=iOS,id=<device-udid>' -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{d=$2} / FULL_PRODUCT_NAME /{n=$2} END{print d"/"n}')
xcrun devicectl device install app --device <device-udid> "$APP"
xcrun devicectl device process launch --device <device-udid> com.kuulla.app
```

On-device API target: physical devices can't reach the Mac's `localhost`, and Xcode
scheme env vars (`KUULLA_API_BASE_URL`) aren't injected into on-device runs. A Debug
build on a device therefore talks to the deployed API (`https://api.kuulla.us`);
`KUULLA_API_BASE_URL` and `localhost:5245` still apply in the Simulator. See
`ApiConfiguration.baseURL` in `ios/Kuulla/Kuulla/ApiClient.swift`.

CarPlay on-device needs the `com.apple.developer.carplay-audio` entitlement, which
Apple has approved for team `96VJBK4H9P` (tracked in #522) and which is enabled on
the `com.kuulla.app` App ID. The key lives in `Kuulla.entitlements`; a normal
automatic-signing on-device build picks it up. See
[docs/carplay-entitlement-runbook.md](docs/carplay-entitlement-runbook.md) for the
verification checklist.

## Architecture

### Service Orchestration (Aspire AppHost)

The AppHost (`src/Kuulla.AppHost/AppHost.cs`) is the entry point for local development. It wires up:
- **CosmosDB** (runs as emulator locally) → referenced by API as `"kuulladb"`
- **API** (`src/Kuulla.Api`) → depends on CosmosDB
- **Web** (`src/Kuulla.Web`) → depends on API via Aspire service discovery (`https+http://api`)
- **Feed poller** (`src/Kuulla.FeedPoller`) → depends on CosmosDB; runs the subscribed-podcast feed sweep

The dependency chain is: Web → API → CosmosDB, and Feed poller → CosmosDB. Aspire handles startup ordering with `WaitFor`.

### Domain layer (`Kuulla.Core`)

`src/Kuulla.Core` holds the domain services (episodes, shows, subscriptions, settings, episode
state, device tokens, feed polling, the podcast directory/feed clients, the SSRF-guarded resource
fetcher) and all the model records. Both the API and the feed poller reference it and wire it with
`AddKuullaCore()` + `AddKuullaNotifications()`. The API keeps only its endpoints plus the
Playlist / Discovery / User / Transcript services.

### Feed polling (`Kuulla.FeedPoller`)

The subscribed-podcast episode pull (`FeedPollingService.PollOnceAsync` in `Kuulla.Core`) runs in
a dedicated worker, **not** an API hosted service — so it runs once per tick regardless of API
replica count. Locally it's an Aspire-orchestrated `PeriodicTimer` worker (`feed-poller`);
in production it's an Azure Container Apps **scheduled job** (cron `*/15`, parallelism 1,
run-one-sweep-and-exit). `POST /dev/poll-feeds` runs one sweep on demand for local testing. See
[docs/feed-poller-runbook.md](docs/feed-poller-runbook.md).

### Service Defaults

`src/Kuulla.ServiceDefaults` is referenced by both API and Web. It configures OpenTelemetry, health checks (`/health`, `/alive`), service discovery, and HTTP resilience. All services call `builder.AddServiceDefaults()` and `app.MapDefaultEndpoints()`.

### Web → API Communication

The Blazor app uses a named `HttpClient("api")` with base address `https+http://api` which Aspire's service discovery resolves at runtime. No hardcoded URLs.

### iOS App

Standalone SwiftUI app in `ios/Kuulla/`. Uses `@Observable` for state, actor-based `ApiClient` for network calls, and `AVPlayer` with background audio mode (`.spokenAudio` category).

## Conventions

### .NET / C#
- File-scoped namespaces
- Primary constructors where appropriate
- Records for DTOs and immutable data
- PascalCase for public members, camelCase for locals/parameters
- Dependency injection via Aspire service defaults

### Blazor
- One component per file
- Server interactivity mode

### Swift / iOS
- SwiftUI with `@Observable`
- async/await for concurrency
- iOS 17+ deployment target

### General
- No commented-out code in commits
- Commit messages: short imperative summary (e.g., "Add playback sync endpoint")
- PRs target `main` branch
- Aspire handles all local service orchestration — no docker-compose

## Pull Request Workflow

- If the work is tied to a GitHub issue, the PR description must reference it with a closing keyword (e.g. `Closes #57`) so the issue auto-closes on merge and stays linked in the milestone. Do not rely on matching titles or manual issue-closing — check before opening the PR.
- Before opening a PR, run `dotnet test Kuulla.sln` (and any relevant iOS tests) locally and get an independent review of the diff from another model (e.g. `/code-review`) — address what both find. PR CI (`pr.yml`) only builds; it does not run the test suite, so this local run is the only test gate.
- Once CI (build) passes, merge the PR and delete its branch.

## Aspire Skills

This repo has Aspire CLI skills installed at `.claude/skills/`. Use them for:
- **aspire** — top-level router, detects AppHost and routes to sub-skills
- **aspire-orchestration** — start/stop/wait/restart lifecycle, recover from port conflicts or file locks
- **aspire-monitoring** — logs, traces, metrics, resource state, telemetry export
- **aspire-deployment** — deploy to Azure, Kubernetes, Docker Compose, or AWS
- **aspire-init** — scaffold new Aspire projects (`aspire new` or `aspire init`)
- **aspireify** — wire resources into an existing AppHost
- **dotnet-inspect** — query .NET APIs across NuGet packages
- **playwright-cli** — browser automation for testing the web frontend

Prefer using these skills over manual CLI invocation when performing multi-step Aspire workflows.

## Key Design Decisions

- Audio quality is the top priority — prefer higher bitrate and proper normalization over bandwidth savings
- Sync must be fast and conflict-free — last-write-wins for playback position, CRDTs if needed for queue ordering
