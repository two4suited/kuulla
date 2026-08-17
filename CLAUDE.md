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

## Architecture

### Service Orchestration (Aspire AppHost)

The AppHost (`src/Kuulla.AppHost/AppHost.cs`) is the entry point for local development. It wires up:
- **CosmosDB** (runs as emulator locally) → referenced by API as `"kuulladb"`
- **Redis** (container) → referenced by API as `"redis"`
- **API** (`src/Kuulla.Api`) → depends on CosmosDB + Redis
- **Web** (`src/Kuulla.Web`) → depends on API via Aspire service discovery (`https+http://api`)

The dependency chain is: Web → API → (CosmosDB, Redis). Aspire handles startup ordering with `WaitFor`.

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

- Before opening a PR, get an independent review of the diff from another model (e.g. `/code-review`) and address what it finds.
- After opening the PR on GitHub, request a review from GitHub Copilot.
- Then loop: poll the PR for new review comments, fix what's actionable, and resolve/reply to each thread once addressed — keep checking back until no unresolved comments remain.
- Once CI checks pass and there are no unresolved review comments, merge the PR and delete its branch.

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
