using Aspire.Hosting;
using Aspire.Hosting.ApplicationModel;
using Aspire.Hosting.Testing;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Playwright;
using Xunit;

namespace Kuulla.Web.E2E;

// Spins up the real AppHost (Web + API + CosmosDB emulator + Redis) once per test collection and
// drives it through a real Chromium browser via Playwright, so tests exercise the actual Blazor
// Server circuit instead of a mocked DOM. Shared across every test in the collection to keep the
// (slow: emulator + browser) startup cost paid once.
public sealed class WebAppFixture : IAsyncLifetime
{
    private DistributedApplication? _app;
    private IPlaywright? _playwright;
    private IBrowser? _browser;

    public Uri WebBaseUri { get; private set; } = null!;

    public async Task InitializeAsync()
    {
        // Same startup race as AppHost.Tests' AppHostFixture (see that file's comment): the
        // preview Cosmos emulator can report its gateway healthy before it's actually ready to
        // serve, which fails "api" (and "web" as a cascade) outright. Retry the whole app
        // startup with a fresh emulator container rather than fighting it at a lower layer.
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

                await resourceNotificationService.WaitForResourceHealthyAsync("cosmos")
                    .WaitAsync(TimeSpan.FromMinutes(5));
                await resourceNotificationService.WaitForResourceAsync("api", KnownResourceStates.Running)
                    .WaitAsync(TimeSpan.FromMinutes(5));
                await resourceNotificationService.WaitForResourceAsync("web", KnownResourceStates.Running)
                    .WaitAsync(TimeSpan.FromMinutes(5));

                _app = app;
                WebBaseUri = app.GetEndpoint("web");
                break;
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

        // xUnit v2 doesn't call DisposeAsync when InitializeAsync throws, so from here on
        // (the AppHost is already up) a failure has to dispose _app itself rather than leaking
        // the emulator/Redis containers and API/Web processes for the rest of the test run.
        try
        {
            // Installs into the shared Playwright browser cache on first run (a no-op if already
            // present) rather than requiring a separate `playwright install` step before `dotnet test`.
            var installExitCode = Microsoft.Playwright.Program.Main(["install", "chromium"]);
            if (installExitCode != 0)
            {
                throw new InvalidOperationException($"Playwright browser install failed with exit code {installExitCode}.");
            }

            _playwright = await Playwright.CreateAsync();
            _browser = await _playwright.Chromium.LaunchAsync(new BrowserTypeLaunchOptions { Headless = true });
        }
        catch
        {
            await _app!.DisposeAsync();
            throw;
        }
    }

    // A fresh browser context (and therefore cookie jar/storage) per call, so a signed-in test
    // doesn't leak its auth cookie into a test that expects to be anonymous.
    public async Task<IPage> NewPageAsync()
    {
        // The "web" endpoint Aspire hands back prefers https, backed by the ASP.NET Core dev
        // certificate — trusted in this machine's system keychain (and so already trusted by a
        // Chromium that reads it, e.g. on macOS), but not something a fresh Playwright browser
        // install can assume on every contributor's machine or CI image.
        var context = await _browser!.NewContextAsync(new BrowserNewContextOptions
        {
            BaseURL = WebBaseUri.ToString(),
            IgnoreHTTPSErrors = true,
        });
        return await context.NewPageAsync();
    }

    // A fresh client per call, matching AppHostFixture's CreateApiClient — used to seed data
    // directly through the API's real Cosmos wiring ahead of a browser test.
    public HttpClient CreateApiClient() => _app!.CreateHttpClient("api");

    public async Task DisposeAsync()
    {
        if (_browser is not null)
        {
            await _browser.DisposeAsync();
        }

        _playwright?.Dispose();

        if (_app is not null)
        {
            await _app.DisposeAsync();
        }
    }
}

[CollectionDefinition(Name)]
public sealed class WebAppCollection : ICollectionFixture<WebAppFixture>
{
    public const string Name = "WebApp";
}
