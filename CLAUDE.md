# CLAUDE.md

## Project Overview

Kuulla is a podcast app focused on audio quality and fast syncing, with a .NET backend, Blazor web frontend, and Swift iOS app. Runs on Azure in production, uses .NET Aspire for local development orchestration.

## Tech Stack

- **Backend**: .NET 10 (C#)
- **Web Frontend**: Blazor (Server interactivity)
- **iOS**: Swift
- **Database**: Azure CosmosDB
- **Cache**: Redis
- **Local Dev**: .NET Aspire 13.4.6
- **Cloud**: Azure

## Project Structure

```
src/
  Kuulla.AppHost/        # Aspire orchestrator
  Kuulla.ServiceDefaults/ # Shared service configuration
  Kuulla.Api/            # Backend API
  Kuulla.Web/            # Blazor frontend
ios/
  Kuulla/               # Swift iOS app
```

## Development

### Running locally

```sh
dotnet run --project src/Kuulla.AppHost
```

### Building

```sh
dotnet build
```

### Testing

```sh
dotnet test
```

## Conventions

### .NET / C#

- Use file-scoped namespaces
- Use primary constructors where appropriate
- Prefer records for DTOs and immutable data
- Follow standard .NET naming: PascalCase for public members, camelCase for locals/parameters
- Use dependency injection via Aspire service defaults

### Blazor

- One component per file
- Keep components small and focused
- Use render modes appropriate to the component's needs

### Swift / iOS

- Follow Swift API design guidelines
- Use SwiftUI for UI
- Use async/await for concurrency

### General

- No commented-out code in commits
- Commit messages: short imperative summary (e.g., "Add playback sync endpoint")
- PRs target `main` branch

## Key Design Decisions

- Audio quality is the top priority — prefer higher bitrate and proper normalization over bandwidth savings
- Sync must be fast and conflict-free — last-write-wins for playback position, CRDTs if needed for queue ordering
- Aspire handles all local service orchestration — no docker-compose
