# Kuulla

A podcast app built for audio quality and fast syncing, with web and iOS interfaces.

## Goals

- **Audio quality first** — prioritize high-bitrate streams, gapless playback, and proper audio normalization
- **Fast syncing** — playback position, subscriptions, and queue sync instantly across devices
- **Cross-platform** — native iOS app and a web interface sharing the same backend

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Backend | .NET (C#) |
| Web Frontend | Blazor |
| iOS | Swift |
| Local Dev | .NET Aspire |
| Cloud | Azure |

## Architecture

- **Backend (.NET)** — API for sync, feed management, and audio delivery
- **Web (Blazor)** — browser-based player and subscription management
- **iOS (Swift)** — native app with background audio, offline support, and system integration
- **Aspire** — local development orchestration and service defaults

## Development

### Prerequisites

- .NET 9+ SDK
- .NET Aspire workload
- Xcode (for iOS development)

### Running locally

```sh
dotnet run --project src/Kuulla.AppHost
```

## Deployment

Hosted on Azure. Infrastructure and deployment details TBD.

## License

TBD
