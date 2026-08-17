using Aspire.Hosting;
using Aspire.Hosting.ApplicationModel;
using Aspire.Hosting.Testing;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace Kuulla.AppHost.Tests;

// Spins up the real AppHost (API + CosmosDB emulator + Redis) once per test collection so tests
// exercise the actual wiring instead of mocks. Slow to start (pulls/boots the Cosmos emulator
// container) but shared across every test in the collection to keep overall runtime reasonable.
public sealed class AppHostFixture : IAsyncLifetime
{
    private DistributedApplication? _app;

    public async Task InitializeAsync()
    {
        // The preview Cosmos emulator has a startup race: its gateway can report healthy
        // slightly before the "pgcosmos" query engine behind it is ready, and Aspire's own
        // dependency-readiness probe for the "cosmos"-dependent resources doesn't retry on
        // that specific transient 503 — it fails "api" (and "web" as a cascade) outright.
        // Retrying the whole app startup with a fresh emulator container is the only lever
        // available at this layer.
        const int maxAttempts = 3;
        for (var attempt = 1; attempt <= maxAttempts; attempt++)
        {
            DistributedApplication? app = null;
            try
            {
                var appHost = await DistributedApplicationTestingBuilder.CreateAsync<Projects.Kuulla_AppHost>();
                app = await appHost.BuildAsync();
                await app.StartAsync();

                var resourceNotificationService = app.Services.GetRequiredService<ResourceNotificationService>();

                // "Running" just means the container process/API process has launched — the
                // Cosmos emulator's own gateway takes several minutes longer to actually start
                // accepting requests, so wait for its health check (not just Running) too.
                await resourceNotificationService.WaitForResourceHealthyAsync("cosmos")
                    .WaitAsync(TimeSpan.FromMinutes(5));
                await resourceNotificationService.WaitForResourceAsync("api", KnownResourceStates.Running)
                    .WaitAsync(TimeSpan.FromMinutes(5));

                _app = app;
                return;
            }
            catch when (attempt < maxAttempts)
            {
                if (app is not null)
                {
                    await app.DisposeAsync();
                }
            }
            catch
            {
                if (app is not null)
                {
                    await app.DisposeAsync();
                }

                throw;
            }
        }
    }

    // A fresh client per call — tests set per-client auth headers, so a shared instance would
    // leak state (or break once one test disposes it) across tests in the collection.
    public HttpClient CreateApiClient() => _app!.CreateHttpClient("api");

    public async Task DisposeAsync()
    {
        if (_app is not null)
        {
            await _app.DisposeAsync();
        }
    }
}

[CollectionDefinition(Name)]
public sealed class AppHostCollection : ICollectionFixture<AppHostFixture>
{
    public const string Name = "AppHost";
}
