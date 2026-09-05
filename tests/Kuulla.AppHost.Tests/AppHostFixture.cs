using Aspire.Hosting;
using Aspire.Hosting.ApplicationModel;
using Aspire.Hosting.Testing;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Playwright;
using Xunit;

namespace Kuulla.AppHost.Tests;

// Spins up the real AppHost (API + Web + CosmosDB emulator) once per test collection so
// tests exercise the actual wiring instead of mocks. Slow to start (pulls/boots the Cosmos
// emulator container) but shared across every test in the collection — the HTTP-level flow tests
// and the Playwright browser E2E tests both take a dependency on this one fixture, so the
// emulator boots once for the whole assembly rather than once per test project.
public sealed class AppHostFixture : IAsyncLifetime
{
    private DistributedApplication? _app;

    // Playwright is initialized lazily on the first NewPageAsync() call rather than in
    // InitializeAsync: the HTTP-only flow tests never touch a browser, so a run that only
    // executes those shouldn't pay the Chromium install-check + launch cost.
    private readonly SemaphoreSlim _browserInitLock = new(1, 1);
    private IPlaywright? _playwright;
    private IBrowser? _browser;

    public Uri WebBaseUri { get; private set; } = null!;

    public async Task InitializeAsync()
    {
        // The preview Cosmos emulator has a startup race: its gateway can report healthy
        // slightly before the "pgcosmos" query engine behind it is ready, and Aspire's own
        // dependency-readiness probe for the "cosmos"-dependent resources doesn't retry on
        // that specific transient 503 — it fails "api" (and "web" as a cascade) outright.
        // Retrying the whole app startup with a fresh emulator container is the only lever
        // available at this layer. One retry is enough for the genuine race; a run that fails
        // twice is a real wiring problem, not a flake, and shouldn't burn another full boot.
        const int maxAttempts = 2;
        for (var attempt = 1; attempt <= maxAttempts; attempt++)
        {
            DistributedApplication? app = null;
            try
            {
                var appHost = await DistributedApplicationTestingBuilder.CreateAsync<Projects.Kuulla_AppHost>();
                app = await appHost.BuildAsync();
                await app.StartAsync();

                var resourceNotificationService = app.Services.GetRequiredService<ResourceNotificationService>();

                // The Cosmos emulator's gateway genuinely takes a few minutes to come up, so it
                // gets the long timeout. "api"/"web" only have to reach Running once their
                // dependencies are healthy — that's quick, so a short timeout there turns a
                // real startup failure into a fast retry instead of a 5-minute hang.
                await resourceNotificationService.WaitForResourceHealthyAsync("cosmos")
                    .WaitAsync(TimeSpan.FromMinutes(5));
                await resourceNotificationService.WaitForResourceAsync("api", KnownResourceStates.Running)
                    .WaitAsync(TimeSpan.FromMinutes(2));
                await resourceNotificationService.WaitForResourceAsync("web", KnownResourceStates.Running)
                    .WaitAsync(TimeSpan.FromMinutes(2));

                _app = app;
                WebBaseUri = app.GetEndpoint("web");
                return;
            }
            catch (Exception ex) when (attempt < maxAttempts)
            {
                Console.WriteLine($"AppHostFixture: startup attempt {attempt}/{maxAttempts} failed, retrying with a fresh AppHost. {ex.GetType().Name}: {ex.Message}");
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

    // A fresh browser context (and therefore cookie jar/storage) per call, so a signed-in test
    // doesn't leak its auth cookie into a test that expects to be anonymous.
    public async Task<IPage> NewPageAsync()
    {
        var browser = await GetBrowserAsync();

        // The "web" endpoint Aspire hands back prefers https, backed by the ASP.NET Core dev
        // certificate — trusted in this machine's system keychain (and so already trusted by a
        // Chromium that reads it, e.g. on macOS), but not something a fresh Playwright browser
        // install can assume on every contributor's machine or CI image.
        var context = await browser.NewContextAsync(new BrowserNewContextOptions
        {
            BaseURL = WebBaseUri.ToString(),
            IgnoreHTTPSErrors = true,
        });
        return await context.NewPageAsync();
    }

    private async Task<IBrowser> GetBrowserAsync()
    {
        if (_browser is not null)
        {
            return _browser;
        }

        await _browserInitLock.WaitAsync();
        try
        {
            if (_browser is null)
            {
                // Installs into the shared Playwright browser cache on first run (a no-op if
                // already present) rather than requiring a separate `playwright install` step
                // before `dotnet test`.
                var installExitCode = Microsoft.Playwright.Program.Main(["install", "chromium"]);
                if (installExitCode != 0)
                {
                    throw new InvalidOperationException($"Playwright browser install failed with exit code {installExitCode}.");
                }

                _playwright = await Playwright.CreateAsync();
                _browser = await _playwright.Chromium.LaunchAsync(new BrowserTypeLaunchOptions { Headless = true });
            }
        }
        finally
        {
            _browserInitLock.Release();
        }

        return _browser;
    }

    public async Task DisposeAsync()
    {
        if (_browser is not null)
        {
            await _browser.DisposeAsync();
        }

        _playwright?.Dispose();
        _browserInitLock.Dispose();

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
