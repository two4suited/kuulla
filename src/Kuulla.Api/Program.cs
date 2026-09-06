using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;
using System.Security.Cryptography;
using Kuulla.Api.Services;
using Kuulla.Core;
using Kuulla.Core.Models;
using Kuulla.Core.Services;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.Azure.Cosmos;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.IdentityModel.Tokens;

var builder = WebApplication.CreateBuilder(args);

builder.AddServiceDefaults();
builder.AddAzureCosmosClient("kuulladb");
builder.AddAzureCosmosContainer("users");
builder.AddKeyedAzureCosmosContainer("shows");
builder.AddKeyedAzureCosmosContainer("episodes");
builder.AddKeyedAzureCosmosContainer("subscriptions");
builder.AddKeyedAzureCosmosContainer("settings");
builder.AddKeyedAzureCosmosContainer("episodestates");
builder.AddKeyedAzureCosmosContainer("playlists");
builder.AddKeyedAzureCosmosContainer("devicetokens");

// Domain services (feed polling, episodes, shows, subscriptions, settings, episode state, device
// tokens, the podcast directory/feed HTTP clients and the SSRF-guarded resource fetcher) now live
// in Kuulla.Core so the Kuulla.FeedPoller worker can share the exact same registrations (#38).
builder.Services.AddKuullaCore();

// API-only services that stayed behind: they front HTTP endpoints rather than the feed-poll path.
builder.Services.AddScoped<IUserService, UserService>();
builder.Services.AddScoped<IDiscoveryService, DiscoveryService>();
builder.Services.AddScoped<IPlaylistService, PlaylistService>();
builder.Services.AddScoped<ITranscriptService, TranscriptService>();

// The feed-polling sweep no longer runs in the API — the Kuulla.FeedPoller worker (an ACA
// scheduled job in production) owns it now, so it runs once per tick instead of once per API
// replica (#38). IFeedPollingService stays registered (via AddKuullaCore) for the dev-only
// /dev/poll-feeds endpoint.

// Push-notification sender (APNs, or a no-op fallback when APNs isn't configured). Shared with
// the Kuulla.FeedPoller worker, which sends the same new-episode push (milestone #32, issue #216).
builder.Services.AddKuullaNotifications(
    builder.Configuration, useSandbox: builder.Environment.IsDevelopment());

var googleClientId = builder.Configuration["Google:ClientId"];
var googleIosClientId = builder.Configuration["Google:IosClientId"];
var googleAudiences = new[] { googleClientId, googleIosClientId }
    .Where(audience => !string.IsNullOrEmpty(audience))
    .ToArray();

// Local testing (issue #48) needs to reach authenticated endpoints without real Google OAuth
// credentials configured, so the "at least one audience configured" guard only applies outside
// Development — the LocalTest scheme below covers auth in Development instead.
if (googleAudiences.Length == 0)
{
    if (!builder.Environment.IsDevelopment())
    {
        throw new InvalidOperationException(
            "No Google OAuth client IDs configured. Set 'Google:ClientId' and/or 'Google:IosClientId' " +
            "so JWT bearer authentication has a valid audience to check tokens against.");
    }

    Console.WriteLine(
        "warn: No Google OAuth client IDs configured — real Google sign-in will fail token " +
        "validation. Local testing via POST /dev/test-token (issue #48) is unaffected.");
}

#if DEBUG
const string GoogleScheme = "Google";
const string LocalTestScheme = "LocalTest";
const string LocalTestIssuer = "kuulla-local-test";
const string LocalTestAudience = "kuulla-local-test-client";
#endif

async Task ValidateUserClaimsAsync(Microsoft.AspNetCore.Authentication.JwtBearer.TokenValidatedContext context, string missingClaimsTokenDescription)
{
    var principal = context.Principal!;
    var subject = principal.FindFirstValue(JwtRegisteredClaimNames.Sub);
    var email = principal.FindFirstValue(JwtRegisteredClaimNames.Email);
    if (subject is null || email is null)
    {
        context.Fail($"{missingClaimsTokenDescription} is missing required 'sub' or 'email' claims.");
        return;
    }

    var name = principal.FindFirstValue("name");
    var pictureUrl = principal.FindFirstValue("picture");

    var userService = context.HttpContext.RequestServices.GetRequiredService<IUserService>();
    await userService.GetOrCreateUserAsync(subject, email, name, pictureUrl, context.HttpContext.RequestAborted);
}

#if DEBUG
// Only generated (and only ever validated against) when running locally, so a LocalTest-issued
// token can never be accepted by a non-Development instance of the API. Guarded by #if DEBUG,
// not just IsDevelopment(), so none of this exists in a Release build regardless of how
// ASPNETCORE_ENVIRONMENT is configured on the deployed instance.
SymmetricSecurityKey? localTestSigningKey = null;
var jwtHandler = new JwtSecurityTokenHandler();
if (builder.Environment.IsDevelopment())
{
    localTestSigningKey = new SymmetricSecurityKey(RandomNumberGenerator.GetBytes(32));
}
#endif

void ConfigureGoogleOptions(JwtBearerOptions options)
{
    // Authority-based discovery pulls Google's OpenID configuration (issuer + signing
    // keys) from https://accounts.google.com/.well-known/openid-configuration, which
    // covers issuer and signature validation. Audience still needs to be set explicitly
    // per client (web + iOS use different Google OAuth client IDs).
    options.Authority = "https://accounts.google.com";
    // Without this, JwtSecurityTokenHandler remaps well-known claim types on the way in
    // (e.g. "sub" -> ClaimTypes.NameIdentifier), so lookups by the raw JWT claim names
    // below would silently miss.
    options.MapInboundClaims = false;
    options.TokenValidationParameters = new TokenValidationParameters
    {
        ValidAudiences = googleAudiences,
        NameClaimType = "name",
    };
    options.Events = new JwtBearerEvents
    {
        OnTokenValidated = context => ValidateUserClaimsAsync(context, "Google ID token"),
    };
}

var authenticationBuilder = builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme);

#if DEBUG
if (builder.Environment.IsDevelopment())
{
    // A policy scheme picks which real scheme handles the request by peeking at the token's
    // (unvalidated) issuer claim, so Google-issued and LocalTest-issued tokens can both hit the
    // same "Bearer" default scheme without the caller needing to know which one it has. This
    // indirection (and the LocalTest scheme itself) only exists in Development.
    authenticationBuilder.AddPolicyScheme(JwtBearerDefaults.AuthenticationScheme, JwtBearerDefaults.AuthenticationScheme, options =>
    {
        options.ForwardDefaultSelector = context =>
        {
            var authorizationHeader = context.Request.Headers.Authorization.ToString();
            if (!authorizationHeader.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase))
            {
                return GoogleScheme;
            }

            var token = authorizationHeader["Bearer ".Length..].Trim();
            try
            {
                var issuer = jwtHandler.ReadJwtToken(token).Issuer;
                return issuer == LocalTestIssuer ? LocalTestScheme : GoogleScheme;
            }
            catch (Exception)
            {
                return GoogleScheme;
            }
        };
    });
    authenticationBuilder.AddJwtBearer(GoogleScheme, ConfigureGoogleOptions);
    authenticationBuilder.AddJwtBearer(LocalTestScheme, options =>
    {
        options.MapInboundClaims = false;
        options.TokenValidationParameters = new TokenValidationParameters
        {
            ValidateIssuer = true,
            ValidIssuer = LocalTestIssuer,
            ValidateAudience = true,
            ValidAudience = LocalTestAudience,
            ValidateIssuerSigningKey = true,
            // Non-null: this scheme is only ever registered inside the enclosing
            // `if (builder.Environment.IsDevelopment())`, the same condition under which
            // localTestSigningKey is generated above.
            IssuerSigningKey = localTestSigningKey!,
            ValidAlgorithms = [SecurityAlgorithms.HmacSha256],
            NameClaimType = "name",
        };
        options.Events = new JwtBearerEvents
        {
            OnTokenValidated = context => ValidateUserClaimsAsync(context, "Local test token"),
        };
    });
}
else
{
    authenticationBuilder.AddJwtBearer(JwtBearerDefaults.AuthenticationScheme, ConfigureGoogleOptions);
}
#else
authenticationBuilder.AddJwtBearer(JwtBearerDefaults.AuthenticationScheme, ConfigureGoogleOptions);
#endif

builder.Services.AddAuthorization();

var app = builder.Build();

app.MapDefaultEndpoints();
app.UseFrontDoorIdRestriction();

app.UseAuthentication();
app.UseAuthorization();

app.MapGet("/health", () => Results.Ok(new { status = "healthy" }));

#if DEBUG
if (app.Environment.IsDevelopment())
{
    // Restricts the /dev/* endpoints below to loopback callers even though they're already
    // Development/DEBUG-only, so they can't be reached by anyone who merely reaches the
    // machine over a shared network.
    static bool IsLoopbackCaller(HttpContext context)
    {
        var remoteIp = context.Connection.RemoteIpAddress;
        return remoteIp is not null && System.Net.IPAddress.IsLoopback(remoteIp);
    }

    // Local-testing-only (issue #48): mints a token that satisfies the same validation the
    // Google scheme applies (issuer, signature, sub/email claims) so Web/iOS can exercise
    // authenticated flows without a real Google sign-in. Never registered outside Development,
    // and compiled out of Release builds entirely regardless of ASPNETCORE_ENVIRONMENT.
    // Optional ?sub= lets integration tests mint a token for an isolated per-test user instead
    // of all sharing "local-test-user" and colliding on that user's global settings/subscriptions.
    app.MapPost("/dev/test-token", (HttpContext context, string? sub) =>
    {
        if (!IsLoopbackCaller(context))
        {
            return Results.StatusCode(StatusCodes.Status403Forbidden);
        }

        var subject = string.IsNullOrWhiteSpace(sub) ? "local-test-user" : sub;
        var claims = new[]
        {
            new Claim(JwtRegisteredClaimNames.Sub, subject),
            new Claim(JwtRegisteredClaimNames.Email, $"{subject}@local.kuulla.dev"),
            new Claim("name", "Local Test User"),
        };
        var token = new JwtSecurityToken(
            issuer: LocalTestIssuer,
            audience: LocalTestAudience,
            claims: claims,
            expires: DateTime.UtcNow.AddHours(12),
            signingCredentials: new SigningCredentials(localTestSigningKey, SecurityAlgorithms.HmacSha256));

        return Results.Ok(new { token = jwtHandler.WriteToken(token) });
    });

    // Local-testing-only (issue #57): lets integration tests seed a Show directly into Cosmos
    // through the API's own already-configured client, instead of standing up a second Cosmos
    // client/connection from the test process. Same loopback + Development + DEBUG guard as
    // /dev/test-token above.
    app.MapPost("/dev/seed-show", async (
        HttpContext context,
        Show show,
        [FromKeyedServices("shows")] Container showsContainer,
        CancellationToken ct) =>
    {
        if (!IsLoopbackCaller(context))
        {
            return Results.StatusCode(StatusCodes.Status403Forbidden);
        }

        if (string.IsNullOrWhiteSpace(show.Id)
            || string.IsNullOrWhiteSpace(show.Title)
            || string.IsNullOrWhiteSpace(show.Author)
            || string.IsNullOrWhiteSpace(show.FeedUrl)
            || show.Categories is null)
        {
            return Results.BadRequest(new
            {
                error = "'id', 'title', 'author', 'feedUrl', and 'categories' are required.",
            });
        }

        try
        {
            await showsContainer.CreateItemAsync(show, new PartitionKey(show.Id), cancellationToken: ct);
        }
        catch (CosmosException ex) when (ex.StatusCode == System.Net.HttpStatusCode.Conflict)
        {
            // Create-only, matching ShowService's caching behavior (src/Kuulla.Api/Services/ShowService.cs)
            // — never clobber a show that's already been seeded or enriched with a feed-derived
            // description.
        }

        return Results.Ok(show);
    });

    // Local-testing-only: lets integration tests seed Episodes directly into Cosmos, mirroring
    // EpisodeService.CacheEpisodesAsync's create-only insert, without standing up a real feed
    // for the show or a second Cosmos client from the test process. Same loopback + Development
    // + DEBUG guard as the other /dev/* endpoints above.
    app.MapPost("/dev/seed-episodes", async (
        HttpContext context,
        List<Episode> episodes,
        [FromKeyedServices("episodes")] Container episodesContainer,
        CancellationToken ct) =>
    {
        if (!IsLoopbackCaller(context))
        {
            return Results.StatusCode(StatusCodes.Status403Forbidden);
        }

        foreach (var episode in episodes)
        {
            try
            {
                await episodesContainer.CreateItemAsync(
                    episode, new PartitionKey(episode.ShowId), cancellationToken: ct);
            }
            catch (CosmosException ex) when (ex.StatusCode == System.Net.HttpStatusCode.Conflict)
            {
            }
        }

        return Results.Ok(episodes);
    });

    // Local-testing-only (Dynamic Playlist Auto-Ordering milestone, #112): unlike /dev/seed-episodes
    // above, this drives the real EpisodeService.CacheEpisodesAsync path — the same one a live feed
    // refresh takes — instead of writing straight into Cosmos. That matters here because the thing
    // under test *is* the enforcement CacheEpisodesAsync triggers (unlistened-limit marking, and
    // now dynamic-playlist auto-insert/evict), not just the episodes' existence. Same loopback +
    // Development + DEBUG guard as the other /dev/* endpoints above.
    app.MapPost("/dev/simulate-new-episodes", async (
        HttpContext context,
        SimulateNewEpisodesRequest request,
        IEpisodeService episodeService,
        CancellationToken ct) =>
    {
        if (!IsLoopbackCaller(context))
        {
            return Results.StatusCode(StatusCodes.Status403Forbidden);
        }

        await episodeService.CacheEpisodesAsync(request.ShowId, request.Episodes, ct);
        return Results.Ok(request.Episodes);
    });

    // Local-testing-only (milestone #38): runs one feed-polling sweep on demand — the exact path
    // the Kuulla.FeedPoller worker runs on its timer — so a local test doesn't have to wait out a
    // full FeedPolling:IntervalMinutes tick. Pair it with /dev/simulate-new-episodes (to inject a
    // synthetic episode) or point a seeded Show's FeedUrl at a feed you control to watch a new
    // episode flow through caching + the new-episode push. Same loopback + Development + DEBUG
    // guard as the other /dev/* endpoints above.
    app.MapPost("/dev/poll-feeds", async (
        HttpContext context,
        IFeedPollingService feedPollingService,
        CancellationToken ct) =>
    {
        if (!IsLoopbackCaller(context))
        {
            return Results.StatusCode(StatusCodes.Status403Forbidden);
        }

        await feedPollingService.PollOnceAsync(ct);
        return Results.Ok(new { status = "swept" });
    });

    // Local-testing-only (issue #249): lets integration tests seed manual and dynamic Playlists
    // directly into Cosmos, mirroring PlaylistService's own UpsertItemAsync (playlists are
    // upserted, not create-only, so a re-seed with the same id just overwrites — no special
    // conflict handling needed here). Same loopback + Development + DEBUG guard as the other
    // /dev/* endpoints above.
    app.MapPost("/dev/seed-playlists", async (
        HttpContext context,
        List<Playlist> playlists,
        [FromKeyedServices("playlists")] Container playlistsContainer,
        CancellationToken ct) =>
    {
        if (!IsLoopbackCaller(context))
        {
            return Results.StatusCode(StatusCodes.Status403Forbidden);
        }

        foreach (var playlist in playlists)
        {
            await playlistsContainer.UpsertItemAsync(
                playlist, new PartitionKey(playlist.UserId), cancellationToken: ct);
        }

        return Results.Ok(playlists);
    });

    // Local-testing-only (issue #249): lets integration tests seed Subscriptions directly into
    // Cosmos, mirroring SubscriptionService's create-only insert (POST /api/subscriptions),
    // without going through show-search + subscribe just to get a user subscribed to a
    // fixture show. Same loopback + Development + DEBUG guard as the other /dev/* endpoints
    // above.
    app.MapPost("/dev/seed-subscriptions", async (
        HttpContext context,
        List<Subscription> subscriptions,
        [FromKeyedServices("subscriptions")] Container subscriptionsContainer,
        CancellationToken ct) =>
    {
        if (!IsLoopbackCaller(context))
        {
            return Results.StatusCode(StatusCodes.Status403Forbidden);
        }

        var seeded = new List<Subscription>(subscriptions.Count);
        foreach (var subscription in subscriptions)
        {
            try
            {
                await subscriptionsContainer.CreateItemAsync(
                    subscription, new PartitionKey(subscription.UserId), cancellationToken: ct);
                seeded.Add(subscription);
            }
            catch (CosmosException ex) when (ex.StatusCode == System.Net.HttpStatusCode.Conflict)
            {
                // Matches SubscriptionService.SubscribeAsync: create-only, and on conflict the
                // response reflects what's actually stored rather than the (possibly different)
                // payload that lost the race, so a re-seed can't mislead a test into asserting
                // against data that was never written.
                var existing = await subscriptionsContainer.ReadItemAsync<Subscription>(
                    subscription.Id, new PartitionKey(subscription.UserId), cancellationToken: ct);
                seeded.Add(existing.Resource);
            }
        }

        return Results.Ok(seeded);
    });

    // Local-testing-only (issue #249): lets integration tests seed EpisodeStates (playback
    // position/listened status) directly into Cosmos, mirroring EpisodeStateService's own
    // UpsertItemAsync, so tests covering playback-sync/unlistened-limit/auto-archive flows can
    // set up prior listening history without replaying PUT /api/episodes/{id}/state one call at
    // a time. Same loopback + Development + DEBUG guard as the other /dev/* endpoints above.
    app.MapPost("/dev/seed-episode-states", async (
        HttpContext context,
        List<EpisodeState> episodeStates,
        [FromKeyedServices("episodestates")] Container episodeStatesContainer,
        CancellationToken ct) =>
    {
        if (!IsLoopbackCaller(context))
        {
            return Results.StatusCode(StatusCodes.Status403Forbidden);
        }

        foreach (var episodeState in episodeStates)
        {
            await episodeStatesContainer.UpsertItemAsync(
                episodeState, new PartitionKey(episodeState.UserId), cancellationToken: ct);
        }

        return Results.Ok(episodeStates);
    });
}
#endif

app.MapGet("/me", (ClaimsPrincipal user) => Results.Ok(new
{
    Subject = user.FindFirstValue(JwtRegisteredClaimNames.Sub),
    Email = user.FindFirstValue(JwtRegisteredClaimNames.Email),
    Name = user.FindFirstValue("name"),
    PictureUrl = user.FindFirstValue("picture"),
})).RequireAuthorization();

var shows = app.MapGroup("/api/shows");

shows.MapGet("/search", async (string? q, IShowService showService, CancellationToken ct) =>
{
    if (string.IsNullOrWhiteSpace(q))
    {
        return Results.BadRequest(new { error = "Query parameter 'q' is required." });
    }

    var results = await showService.SearchAsync(q, ct);
    return Results.Ok(results);
});

shows.MapGet("/{id}", async (string id, IShowService showService, CancellationToken ct) =>
{
    var show = await showService.GetByIdAsync(id, ct);
    return show is not null ? Results.Ok(show) : Results.NotFound();
});

shows.MapGet("/{id}/episodes", async (
    string id,
    string? continuationToken,
    int? pageSize,
    IShowService showService,
    IEpisodeService episodeService,
    CancellationToken ct) =>
{
    var show = await showService.GetByIdAsync(id, ct);
    if (show is null)
    {
        return Results.NotFound();
    }

    var size = Math.Clamp(pageSize ?? 20, 1, 100);
    var page = await episodeService.GetEpisodesAsync(id, continuationToken, size, ct);
    return Results.Ok(page);
});

shows.MapGet("/{id}/episodes/{episodeId}", async (
    string id,
    string episodeId,
    IEpisodeService episodeService,
    CancellationToken ct) =>
{
    var episode = await episodeService.GetEpisodeAsync(id, episodeId, ct);
    return episode is not null ? Results.Ok(episode) : Results.NotFound();
});

// Timed transcript segments for an episode, normalized from whatever format the feed's
// podcast:transcript tag pointed at (JSON / SRT / VTT). 404 when the episode doesn't exist, has
// no transcript tag, or the referenced document can't be fetched or parsed into segments.
shows.MapGet("/{id}/episodes/{episodeId}/transcript", async (
    string id,
    string episodeId,
    IEpisodeService episodeService,
    ITranscriptService transcriptService,
    CancellationToken ct) =>
{
    var episode = await episodeService.GetEpisodeAsync(id, episodeId, ct);
    if (episode?.TranscriptUrl is null)
    {
        return Results.NotFound();
    }

    var transcript = await transcriptService.GetTranscriptAsync(episode.TranscriptUrl, episode.TranscriptType, ct);
    return transcript is not null ? Results.Ok(transcript) : Results.NotFound();
});

var discovery = app.MapGroup("/api/discovery");

discovery.MapGet("", async (IDiscoveryService discoveryService, CancellationToken ct) =>
{
    var overview = await discoveryService.GetOverviewAsync(ct);
    return Results.Ok(overview);
});

discovery.MapGet("/categories/{categoryId}", async (string categoryId, IDiscoveryService discoveryService, CancellationToken ct) =>
{
    var category = await discoveryService.GetCategoryAsync(categoryId, ct);
    return category is not null ? Results.Ok(category) : Results.NotFound();
});

var subscriptions = app.MapGroup("/api/subscriptions").RequireAuthorization();

subscriptions.MapGet("", async (ClaimsPrincipal user, ISubscriptionService subscriptionService, CancellationToken ct) =>
{
    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    var results = await subscriptionService.GetSubscriptionsAsync(userId, ct);
    return Results.Ok(results);
});

subscriptions.MapPost("", async (
    SubscribeRequest request,
    ClaimsPrincipal user,
    ISubscriptionService subscriptionService,
    IServiceScopeFactory scopeFactory,
    CancellationToken ct) =>
{
    if (string.IsNullOrWhiteSpace(request.ShowId))
    {
        return Results.BadRequest(new { error = "'showId' is required." });
    }

    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    var subscription = await subscriptionService.SubscribeAsync(userId, request.ShowId, ct);
    if (subscription is null)
    {
        return Results.NotFound();
    }

    // A show's back catalog was never run through enforcement for this user before now — without
    // this, every episode beyond the unlistened-episode-count setting shows as unplayed until the
    // show happens to publish a new episode. Fired off rather than awaited: a show's back catalog
    // can be large (a full episode query plus a per-episode state read for everything beyond the
    // limit), and subscribing is a common, latency-sensitive action that shouldn't block on it.
    // Runs in its own DI scope since the request's scope (and its `ct`) won't outlive this handler.
    _ = Task.Run(async () =>
    {
        using var scope = scopeFactory.CreateScope();
        try
        {
            var episodeService = scope.ServiceProvider.GetRequiredService<IEpisodeService>();
            await episodeService.EnforceUnlistenedLimitAsync(userId, request.ShowId, CancellationToken.None);
        }
        catch (Exception ex)
        {
            scope.ServiceProvider.GetRequiredService<ILogger<Program>>()
                .LogError(ex, "Failed to enforce unlistened-episode limit for user {UserId} on show {ShowId} after subscribing", userId, request.ShowId);
        }
    });

    return Results.Ok(subscription);
});

subscriptions.MapDelete("/{showId}", async (
    string showId,
    ClaimsPrincipal user,
    ISubscriptionService subscriptionService,
    CancellationToken ct) =>
{
    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    await subscriptionService.UnsubscribeAsync(userId, showId, ct);
    return Results.NoContent();
});

subscriptions.MapGet("/episodes", async (ClaimsPrincipal user, ISubscriptionService subscriptionService, CancellationToken ct) =>
{
    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    var results = await subscriptionService.GetNewEpisodesAsync(userId, ct);
    return Results.Ok(results);
});

var notifications = app.MapGroup("/api/notifications").RequireAuthorization();

notifications.MapPost("/device-token", async (
    RegisterDeviceTokenRequest request,
    ClaimsPrincipal user,
    IDeviceTokenService deviceTokenService,
    CancellationToken ct) =>
{
    if (string.IsNullOrWhiteSpace(request.DeviceId) || string.IsNullOrWhiteSpace(request.ApnsToken))
    {
        return Results.BadRequest(new { error = "'deviceId' and 'apnsToken' are required." });
    }

    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    var token = await deviceTokenService.RegisterAsync(userId, request.DeviceId, request.ApnsToken, request.Platform, ct);
    return Results.Ok(token);
});

notifications.MapDelete("/device-token/{deviceId}", async (
    string deviceId,
    ClaimsPrincipal user,
    IDeviceTokenService deviceTokenService,
    CancellationToken ct) =>
{
    if (string.IsNullOrWhiteSpace(deviceId))
    {
        return Results.BadRequest(new { error = "'deviceId' is required." });
    }

    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    await deviceTokenService.UnregisterAsync(userId, deviceId, ct);
    return Results.NoContent();
});

var episodeState = app.MapGroup("/api/episodes").RequireAuthorization();

episodeState.MapGet("/{id}/state", async (
    string id,
    ClaimsPrincipal user,
    IEpisodeStateService episodeStateService,
    CancellationToken ct) =>
{
    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    var state = await episodeStateService.GetStateAsync(userId, id, ct);
    return state is not null ? Results.Ok(state) : Results.NotFound();
});

episodeState.MapPost("/states", async (
    GetEpisodeStatesRequest request,
    ClaimsPrincipal user,
    IEpisodeStateService episodeStateService,
    CancellationToken ct) =>
{
    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    var states = await episodeStateService.GetStatesAsync(userId, request.EpisodeIds, ct);
    return Results.Ok(states);
});

episodeState.MapGet("/in-progress-shows", async (
    ClaimsPrincipal user,
    IEpisodeStateService episodeStateService,
    CancellationToken ct) =>
{
    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    var showIds = await episodeStateService.GetInProgressShowIdsAsync(userId, ct);
    return Results.Ok(showIds);
});

episodeState.MapPut("/{id}/state", async (
    string id,
    UpdateEpisodeStateRequest request,
    ClaimsPrincipal user,
    IEpisodeStateService episodeStateService,
    IEpisodeService episodeService,
    CancellationToken ct) =>
{
    if (string.IsNullOrWhiteSpace(request.ShowId))
    {
        return Results.BadRequest(new { error = "'showId' is required." });
    }

    if (request.PositionSeconds < 0)
    {
        return Results.BadRequest(new { error = "'positionSeconds' must be non-negative." });
    }

    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    var result = await episodeStateService.UpdateStateAsync(
        userId, id, request.ShowId, request.PositionSeconds, request.Completed, request.DeviceId, ct);

    // Best-effort, same rationale as the settings-update enforcement calls below: a transient
    // failure here shouldn't turn a successful state update into a 5xx, and it self-heals next
    // time this episode's state changes or the show's auto-archive rule is re-evaluated.
    try
    {
        await episodeService.EnforceAutoArchiveRuleAsync(userId, request.ShowId, ct);
    }
    catch (Exception ex) when (ex is not OperationCanceledException)
    {
        app.Logger.LogError(ex, "Failed to enforce auto-archive rule for user {UserId} on show {ShowId} after an episode state update", userId, request.ShowId);
    }

    return Results.Ok(result);
});

var playlists = app.MapGroup("/api/playlists").RequireAuthorization();

// Shared by POST /api/playlists (Dynamic) and PUT /api/playlists/{id}/config — PriorityList must
// be exactly ShowIds reordered (see DynamicPlaylistConfig.PriorityList's doc comment), so a config
// that drops or adds a show between the two arrays would silently misrank episodes if unvalidated.
static string? ValidateDynamicPlaylistConfig(DynamicPlaylistConfig config)
{
    if (config.ShowIds is null or [])
    {
        return "'showIds' must not be empty.";
    }

    if (config.PriorityList is null or [])
    {
        return "'priorityList' must not be empty.";
    }

    if (config.MaxEpisodes is <= 0)
    {
        return "'maxEpisodes' must be positive.";
    }

    if (config.ShowIds.Count != config.ShowIds.Distinct().Count())
    {
        return "'showIds' must not contain duplicates.";
    }

    // PriorityList also can't contain duplicates — ComputeDynamicItemsAsync builds a
    // showId -> rank dictionary from it, which throws on a duplicate key.
    if (config.PriorityList.Count != config.PriorityList.Distinct().Count())
    {
        return "'priorityList' must not contain duplicates.";
    }

    if (config.PriorityList.ToHashSet().SetEquals(config.ShowIds))
    {
        return null;
    }

    return "'priorityList' must contain exactly the same shows as 'showIds'.";
}

// Shared by POST /api/playlists, PUT /api/playlists/{id} and POST /api/sync/playlists — a
// playlist's Icon must be null or one of the curated set (PlaylistIcons), and AccentColor null
// or a #RRGGBB hex string, so every client renders the same identity (#439).
static string? ValidatePlaylistAppearance(string? icon, string? accentColor)
{
    if (!PlaylistIcons.IsValidIcon(icon))
    {
        return "'icon' must be one of the curated playlist icons.";
    }

    if (!PlaylistIcons.IsValidAccentColor(accentColor))
    {
        return "'accentColor' must be a '#RRGGBB' hex colour.";
    }

    return null;
}

playlists.MapGet("", async (ClaimsPrincipal user, IPlaylistService playlistService, CancellationToken ct) =>
{
    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    var results = await playlistService.GetPlaylistsAsync(userId, ct);
    return Results.Ok(results);
});

playlists.MapPost("", async (
    CreatePlaylistRequest request, ClaimsPrincipal user, IPlaylistService playlistService, CancellationToken ct) =>
{
    if (string.IsNullOrWhiteSpace(request.Name))
    {
        return Results.BadRequest(new { error = "'name' is required." });
    }

    if (!Enum.IsDefined(request.Type))
    {
        return Results.BadRequest(new { error = "'type' must be 'Manual' or 'Dynamic'." });
    }

    var appearanceError = ValidatePlaylistAppearance(request.Icon, request.AccentColor);
    if (appearanceError is not null)
    {
        return Results.BadRequest(new { error = appearanceError });
    }

    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;

    if (request.Type == PlaylistType.Dynamic)
    {
        if (request.DynamicConfig is null)
        {
            return Results.BadRequest(new { error = "'dynamicConfig' is required when 'type' is 'Dynamic'." });
        }

        var configError = ValidateDynamicPlaylistConfig(request.DynamicConfig);
        if (configError is not null)
        {
            return Results.BadRequest(new { error = configError });
        }

        var dynamicPlaylist = await playlistService.CreateDynamicPlaylistAsync(
            userId, request.Name, request.DynamicConfig, request.Icon, request.AccentColor, ct);
        return Results.Ok(dynamicPlaylist);
    }

    var playlist = await playlistService.CreatePlaylistAsync(
        userId, request.Name, request.Icon, request.AccentColor, ct);
    return Results.Ok(playlist);
});

playlists.MapPut("/{id}/config", async (
    string id,
    UpdateDynamicPlaylistConfigRequest request,
    ClaimsPrincipal user,
    IPlaylistService playlistService,
    CancellationToken ct) =>
{
    var config = new DynamicPlaylistConfig(request.ShowIds, request.MaxEpisodes, request.PriorityList);
    var configError = ValidateDynamicPlaylistConfig(config);
    if (configError is not null)
    {
        return Results.BadRequest(new { error = configError });
    }

    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    var playlist = await playlistService.UpdateDynamicPlaylistConfigAsync(userId, id, config, ct);
    return playlist is not null ? Results.Ok(playlist) : Results.NotFound();
});

playlists.MapGet("/{id}", async (string id, ClaimsPrincipal user, IPlaylistService playlistService, CancellationToken ct) =>
{
    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    var detail = await playlistService.GetPlaylistDetailAsync(userId, id, ct);
    return detail is not null ? Results.Ok(detail) : Results.NotFound();
});

playlists.MapPut("/{id}", async (
    string id,
    RenamePlaylistRequest request,
    ClaimsPrincipal user,
    IPlaylistService playlistService,
    CancellationToken ct) =>
{
    if (string.IsNullOrWhiteSpace(request.Name))
    {
        return Results.BadRequest(new { error = "'name' is required." });
    }

    var appearanceError = ValidatePlaylistAppearance(request.Icon, request.AccentColor);
    if (appearanceError is not null)
    {
        return Results.BadRequest(new { error = appearanceError });
    }

    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    var playlist = await playlistService.RenamePlaylistAsync(
        userId, id, request.Name, request.Icon, request.AccentColor, ct);
    return playlist is not null ? Results.Ok(playlist) : Results.NotFound();
});

playlists.MapDelete("/{id}", async (string id, ClaimsPrincipal user, IPlaylistService playlistService, CancellationToken ct) =>
{
    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    await playlistService.DeletePlaylistAsync(userId, id, ct);
    return Results.NoContent();
});

playlists.MapPost("/{id}/items", async (
    string id,
    AddPlaylistItemRequest request,
    ClaimsPrincipal user,
    IPlaylistService playlistService,
    CancellationToken ct) =>
{
    if (string.IsNullOrWhiteSpace(request.EpisodeId) || string.IsNullOrWhiteSpace(request.ShowId))
    {
        return Results.BadRequest(new { error = "'episodeId' and 'showId' are required." });
    }

    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    var playlist = await playlistService.AddItemAsync(userId, id, request.EpisodeId, request.ShowId, ct);
    return playlist is not null ? Results.Ok(playlist) : Results.NotFound();
});

playlists.MapDelete("/{id}/items/{episodeId}", async (
    string id, string episodeId, ClaimsPrincipal user, IPlaylistService playlistService, CancellationToken ct) =>
{
    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    var playlist = await playlistService.RemoveItemAsync(userId, id, episodeId, ct);
    return playlist is not null ? Results.Ok(playlist) : Results.NotFound();
});

playlists.MapPut("/{id}/items/{episodeId}/order", async (
    string id,
    string episodeId,
    ReorderPlaylistItemRequest request,
    ClaimsPrincipal user,
    IPlaylistService playlistService,
    CancellationToken ct) =>
{
    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    try
    {
        var playlist = await playlistService.ReorderItemAsync(
            userId, id, episodeId, request.BeforeEpisodeId, request.AfterEpisodeId, ct);
        return playlist is not null ? Results.Ok(playlist) : Results.NotFound();
    }
    catch (ArgumentException ex)
    {
        // Thrown for a stale/nonexistent neighbor id, or a before/after pair given in the wrong
        // relative order — both are caller errors, not server faults.
        return Results.BadRequest(new { error = ex.Message });
    }
});

var sync = app.MapGroup("/api/sync").RequireAuthorization();

sync.MapPost("/episodes", async (
    SyncEpisodesRequest request,
    ClaimsPrincipal user,
    IEpisodeStateService episodeStateService,
    IEpisodeService episodeService,
    CancellationToken ct) =>
{
    if (string.IsNullOrWhiteSpace(request.DeviceId))
    {
        return Results.BadRequest(new { error = "'deviceId' is required." });
    }

    var changes = request.Changes ?? [];
    foreach (var change in changes)
    {
        if (string.IsNullOrWhiteSpace(change.EpisodeId) || string.IsNullOrWhiteSpace(change.ShowId))
        {
            return Results.BadRequest(new { error = "Each change requires a non-empty 'episodeId' and 'showId'." });
        }

        if (change.PositionSeconds < 0)
        {
            return Results.BadRequest(new { error = "Each change's 'positionSeconds' must be non-negative." });
        }
    }

    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    var result = await episodeStateService.SyncAsync(
        userId, request.DeviceId, request.LastSyncedAt, request.LocalHash, changes, ct);

    // Best-effort, mirrors the direct PUT /api/episodes/{id}/state hook: a client-driven "played"
    // sync (e.g. iOS, which only ever writes via this push endpoint, never the PUT above) should
    // still trigger auto-archive enforcement for any shows it touched. Self-heals next sync.
    var affectedShowIds = changes.Where(c => c.Completed).Select(c => c.ShowId).Distinct();
    foreach (var showId in affectedShowIds)
    {
        try
        {
            await episodeService.EnforceAutoArchiveRuleAsync(userId, showId, ct);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            app.Logger.LogError(ex, "Failed to enforce auto-archive rule for user {UserId} on show {ShowId} after an episode sync", userId, showId);
        }
    }

    return Results.Ok(result);
});

sync.MapPost("/playlists", async (
    SyncPlaylistsRequest request, ClaimsPrincipal user, IPlaylistService playlistService, CancellationToken ct) =>
{
    if (string.IsNullOrWhiteSpace(request.DeviceId))
    {
        return Results.BadRequest(new { error = "'deviceId' is required." });
    }

    var changes = request.Changes ?? [];
    foreach (var change in changes)
    {
        if (string.IsNullOrWhiteSpace(change.Id) || string.IsNullOrWhiteSpace(change.Name))
        {
            return Results.BadRequest(new { error = "Each change requires a non-empty 'id' and 'name'." });
        }

        var appearanceError = ValidatePlaylistAppearance(change.Icon, change.AccentColor);
        if (appearanceError is not null)
        {
            return Results.BadRequest(new { error = appearanceError });
        }
    }

    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    var result = await playlistService.SyncAsync(
        userId, request.DeviceId, request.LastSyncedAt, request.LocalHash, changes, ct);
    return Results.Ok(result);
});

sync.MapPost("/settings", async (
    SyncSettingsRequest request,
    ClaimsPrincipal user,
    ISettingsService settingsService,
    ISubscriptionService subscriptionService,
    IEpisodeService episodeService,
    CancellationToken ct) =>
{
    if (string.IsNullOrWhiteSpace(request.DeviceId))
    {
        return Results.BadRequest(new { error = "'deviceId' is required." });
    }

    // At most one change per call — a device only ever has one UserSettings record to push.
    var changes = request.Changes ?? [];
    if (changes.Count > 1)
    {
        return Results.BadRequest(new { error = "'changes' may contain at most one entry." });
    }

    foreach (var change in changes)
    {
        if (!Enum.IsDefined(change.UnlistenedEpisodeCount))
        {
            return Results.BadRequest(new { error = "'unlistenedEpisodeCount' is not a valid value." });
        }
        if (!Enum.IsDefined(change.AutoArchiveRule))
        {
            return Results.BadRequest(new { error = "'autoArchiveRule' is not a valid value." });
        }
        if (!Enum.IsDefined(change.AutoDeleteRule))
        {
            return Results.BadRequest(new { error = "'autoDeleteRule' is not a valid value." });
        }
        if (!TryValidateAutoSkipSeconds(change.AutoSkipIntroSeconds, "autoSkipIntroSeconds", out var error) ||
            !TryValidateAutoSkipSeconds(change.AutoSkipOutroSeconds, "autoSkipOutroSeconds", out error) ||
            !TryValidatePlaybackSpeed(change.PlaybackSpeed, "playbackSpeed", out error))
        {
            return Results.BadRequest(new { error });
        }
        if (change.AutoDeleteRule == AutoDeleteRule.AfterDays &&
            !TryValidateAutoDeleteAfterDays(change.AutoDeleteAfterDays, "autoDeleteAfterDays", out error))
        {
            return Results.BadRequest(new { error });
        }
        if (!TryValidateNullableSleepTimerDefaultDurationMinutes(
                change.SleepTimerDefaultDurationMinutes, "sleepTimerDefaultDurationMinutes", out error))
        {
            return Results.BadRequest(new { error });
        }
        if (change.UpNextInsertPosition is { } upNextInsertPosition && !Enum.IsDefined(upNextInsertPosition))
        {
            return Results.BadRequest(new { error = "'upNextInsertPosition' is not a valid value." });
        }
    }

    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    var result = await settingsService.SyncAsync(
        userId, request.DeviceId, request.LastSyncedAt, request.LocalHash, changes, ct);

    // Mirrors the enforcement side effects the field-specific PUT endpoints above trigger
    // (settings.MapPut "" and settings.MapPut "/auto-archive") — a change pushed through this
    // endpoint must still re-run them, or a lowered unlistened-episode limit or a tightened
    // auto-archive rule pushed here would silently never prune existing episodes. Runs against
    // the *current* effective settings rather than gating on whether this device's own change won
    // the LWW arbitration, so it's correct either way (both enforcement calls are no-ops when
    // already compliant, matching the PUT endpoints' own rationale). Best-effort, same rationale
    // as the PUT endpoints: the sync write above already succeeded, so a transient enforcement
    // failure shouldn't turn it into a 5xx.
    if (changes.Count > 0)
    {
        try
        {
            var subscriptions = await subscriptionService.GetSubscriptionsAsync(userId, ct);
            await Parallel.ForEachAsync(
                subscriptions,
                new ParallelOptions { MaxDegreeOfParallelism = 20, CancellationToken = ct },
                async (subscription, token) =>
                {
                    await episodeService.EnforceUnlistenedLimitAsync(userId, subscription.ShowId, token);
                    await episodeService.EnforceAutoArchiveRuleAsync(userId, subscription.ShowId, token);
                });
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            app.Logger.LogError(ex, "Failed to enforce settings-derived rules for user {UserId} after a settings sync push", userId);
        }
    }

    return Results.Ok(result);
});

// Upper bound is generous relative to a typical episode's runtime — it exists only to reject
// obviously-wrong input (e.g. a value in milliseconds instead of seconds), not to model any
// real intro/outro length.
const int MaxAutoSkipSeconds = 3600;

bool TryValidateAutoSkipSeconds(int seconds, string fieldName, out string? error)
{
    if (seconds < 0 || seconds > MaxAutoSkipSeconds)
    {
        error = $"'{fieldName}' must be between 0 and {MaxAutoSkipSeconds}.";
        return false;
    }

    error = null;
    return true;
}

bool TryValidateNullableAutoSkipSeconds(int? seconds, string fieldName, out string? error)
{
    if (seconds is { } value)
    {
        return TryValidateAutoSkipSeconds(value, fieldName, out error);
    }

    error = null;
    return true;
}

var settings = app.MapGroup("/api/settings").RequireAuthorization();

settings.MapGet("", async (ClaimsPrincipal user, ISettingsService settingsService, CancellationToken ct) =>
{
    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    var result = await settingsService.GetSettingsAsync(userId, ct);
    return Results.Ok(result);
});

settings.MapPut("", async (
    UpdateSettingsRequest request,
    ClaimsPrincipal user,
    ISettingsService settingsService,
    ISubscriptionService subscriptionService,
    IEpisodeService episodeService,
    CancellationToken ct) =>
{
    if (!Enum.IsDefined(request.UnlistenedEpisodeCount))
    {
        return Results.BadRequest(new { error = "'unlistenedEpisodeCount' is not a valid value." });
    }

    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    var result = await settingsService.UpdateUnlistenedEpisodeCountAsync(userId, request.UnlistenedEpisodeCount, ct);

    // The new global limit only takes effect for shows without a per-show override, but
    // re-running enforcement for every subscribed show is simpler than filtering to those
    // without one — EnforceUnlistenedLimitAsync is a no-op for shows that already comply.
    // Best-effort: the settings update above already succeeded, so a transient enforcement
    // failure (e.g. Cosmos throttling) shouldn't turn a successful update into a 5xx — it'll
    // self-heal next time this show gets a new episode or the limit changes again.
    try
    {
        var subscriptions = await subscriptionService.GetSubscriptionsAsync(userId, ct);
        await Parallel.ForEachAsync(
            subscriptions,
            new ParallelOptions { MaxDegreeOfParallelism = 20, CancellationToken = ct },
            (subscription, token) => new ValueTask(episodeService.EnforceUnlistenedLimitAsync(userId, subscription.ShowId, token)));
    }
    catch (Exception ex) when (ex is not OperationCanceledException)
    {
        app.Logger.LogError(ex, "Failed to enforce unlistened-episode limit for user {UserId} after a global settings update", userId);
    }

    return Results.Ok(result);
});

settings.MapPut("/subscription-sort-order", async (
    UpdateSubscriptionSortOrderRequest request,
    ClaimsPrincipal user,
    ISettingsService settingsService,
    CancellationToken ct) =>
{
    if (!Enum.IsDefined(request.SubscriptionSortOrder))
    {
        return Results.BadRequest(new { error = "'subscriptionSortOrder' is not a valid value." });
    }

    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    var result = await settingsService.UpdateSubscriptionSortOrderAsync(userId, request.SubscriptionSortOrder, ct);
    return Results.Ok(result);
});

settings.MapPut("/subscription-manual-order", async (
    UpdateSubscriptionManualOrderRequest request,
    ClaimsPrincipal user,
    ISettingsService settingsService,
    CancellationToken ct) =>
{
    if (request.ShowIds is null || request.ShowIds.Any(string.IsNullOrWhiteSpace))
    {
        return Results.BadRequest(new { error = "'showIds' must be a list of non-empty show ids." });
    }

    if (request.ShowIds.Distinct(StringComparer.Ordinal).Count() != request.ShowIds.Count)
    {
        return Results.BadRequest(new { error = "'showIds' must not contain duplicates." });
    }

    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    var result = await settingsService.UpdateSubscriptionManualOrderAsync(userId, request.ShowIds, ct);
    return Results.Ok(result);
});

settings.MapPut("/hide-caught-up-shows", async (
    UpdateHideCaughtUpShowsRequest request,
    ClaimsPrincipal user,
    ISettingsService settingsService,
    CancellationToken ct) =>
{
    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    var result = await settingsService.UpdateHideCaughtUpShowsAsync(userId, request.HideCaughtUpShows, ct);
    return Results.Ok(result);
});

settings.MapGet("/shows/{showId}", async (
    string showId,
    ClaimsPrincipal user,
    ISettingsService settingsService,
    CancellationToken ct) =>
{
    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    var result = await settingsService.GetShowSettingsAsync(userId, showId, ct);
    return Results.Ok(result);
});

settings.MapPut("/shows/{showId}", async (
    string showId,
    UpdateShowSettingsRequest request,
    ClaimsPrincipal user,
    ISettingsService settingsService,
    IEpisodeService episodeService,
    CancellationToken ct) =>
{
    if (request.UnlistenedEpisodeCount is { } value && !Enum.IsDefined(value))
    {
        return Results.BadRequest(new { error = "'unlistenedEpisodeCount' is not a valid value." });
    }

    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    var result = await settingsService.UpdateShowUnlistenedEpisodeCountAsync(userId, showId, request.UnlistenedEpisodeCount, ct);

    // Best-effort, same rationale as the global settings endpoint above.
    try
    {
        await episodeService.EnforceUnlistenedLimitAsync(userId, showId, ct);
    }
    catch (Exception ex) when (ex is not OperationCanceledException)
    {
        app.Logger.LogError(ex, "Failed to enforce unlistened-episode limit for user {UserId} on show {ShowId} after a per-show settings update", userId, showId);
    }

    return Results.Ok(result);
});

settings.MapPut("/auto-archive", async (
    UpdateAutoArchiveRuleRequest request,
    ClaimsPrincipal user,
    ISettingsService settingsService,
    ISubscriptionService subscriptionService,
    IEpisodeService episodeService,
    CancellationToken ct) =>
{
    if (!Enum.IsDefined(request.AutoArchiveRule))
    {
        return Results.BadRequest(new { error = "'autoArchiveRule' is not a valid value." });
    }

    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    var result = await settingsService.UpdateAutoArchiveRuleAsync(userId, request.AutoArchiveRule, ct);

    // The new global rule only takes effect for shows without a per-show override, but
    // re-running enforcement for every subscribed show is simpler than filtering to those
    // without one — EnforceAutoArchiveRuleAsync is a no-op for shows whose effective rule is
    // Never. Best-effort, same rationale as the unlistened-episode-limit endpoint above.
    try
    {
        var subscriptions = await subscriptionService.GetSubscriptionsAsync(userId, ct);
        await Parallel.ForEachAsync(
            subscriptions,
            new ParallelOptions { MaxDegreeOfParallelism = 20, CancellationToken = ct },
            (subscription, token) => new ValueTask(episodeService.EnforceAutoArchiveRuleAsync(userId, subscription.ShowId, token)));
    }
    catch (Exception ex) when (ex is not OperationCanceledException)
    {
        app.Logger.LogError(ex, "Failed to enforce auto-archive rule for user {UserId} after a global settings update", userId);
    }

    return Results.Ok(result);
});

settings.MapPut("/shows/{showId}/auto-archive", async (
    string showId,
    UpdateShowAutoArchiveRuleRequest request,
    ClaimsPrincipal user,
    ISettingsService settingsService,
    IEpisodeService episodeService,
    CancellationToken ct) =>
{
    if (request.AutoArchiveRule is { } value && !Enum.IsDefined(value))
    {
        return Results.BadRequest(new { error = "'autoArchiveRule' is not a valid value." });
    }

    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    var result = await settingsService.UpdateShowAutoArchiveRuleAsync(userId, showId, request.AutoArchiveRule, ct);

    // Best-effort, same rationale as the global auto-archive endpoint above.
    try
    {
        await episodeService.EnforceAutoArchiveRuleAsync(userId, showId, ct);
    }
    catch (Exception ex) when (ex is not OperationCanceledException)
    {
        app.Logger.LogError(ex, "Failed to enforce auto-archive rule for user {UserId} on show {ShowId} after a per-show settings update", userId, showId);
    }

    return Results.Ok(result);
});

settings.MapPut("/auto-skip", async (
    UpdateAutoSkipRequest request,
    ClaimsPrincipal user,
    ISettingsService settingsService,
    CancellationToken ct) =>
{
    if (!TryValidateAutoSkipSeconds(request.AutoSkipIntroSeconds, "autoSkipIntroSeconds", out var error) ||
        !TryValidateAutoSkipSeconds(request.AutoSkipOutroSeconds, "autoSkipOutroSeconds", out error))
    {
        return Results.BadRequest(new { error });
    }

    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    var result = await settingsService.UpdateAutoSkipAsync(
        userId, request.AutoSkipIntroSeconds, request.AutoSkipOutroSeconds, ct);
    return Results.Ok(result);
});

settings.MapPut("/shows/{showId}/auto-skip", async (
    string showId,
    UpdateShowAutoSkipRequest request,
    ClaimsPrincipal user,
    ISettingsService settingsService,
    CancellationToken ct) =>
{
    if (!TryValidateNullableAutoSkipSeconds(request.AutoSkipIntroSeconds, "autoSkipIntroSeconds", out var error) ||
        !TryValidateNullableAutoSkipSeconds(request.AutoSkipOutroSeconds, "autoSkipOutroSeconds", out error))
    {
        return Results.BadRequest(new { error });
    }

    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    var result = await settingsService.UpdateShowAutoSkipAsync(
        userId, showId, request.AutoSkipIntroSeconds, request.AutoSkipOutroSeconds, ct);
    return Results.Ok(result);
});

const float MinPlaybackSpeed = 0.5f;
const float MaxPlaybackSpeed = 3.0f;
const float PlaybackSpeedStep = 0.1f;

bool TryValidatePlaybackSpeed(float speed, string fieldName, out string? error)
{
    // NaN compares false against both bounds below, so it would otherwise slip through the
    // range check entirely — reject it explicitly. Infinity is already caught by the bounds
    // themselves (always < Min or > Max); the explicit check here is just for clarity, not
    // because it's load-bearing.
    if (float.IsNaN(speed) || float.IsInfinity(speed) || speed < MinPlaybackSpeed || speed > MaxPlaybackSpeed)
    {
        error = $"'{fieldName}' must be between {MinPlaybackSpeed} and {MaxPlaybackSpeed}.";
        return false;
    }

    // Round-trip through the 0.1 grid rather than a raw modulo check, which is unreliable for
    // floats (e.g. 2.3 % 0.1 doesn't cleanly land on 0 due to binary floating-point rounding).
    // 0.0001 only needs to absorb float round-off (theoretically ~1e-6 over this range) — kept
    // two orders of magnitude above that floor for headroom, while still well below half a step
    // (0.05) so it can't accept a neighboring grid value or a genuinely off-grid input like
    // 0.5009 by mistake.
    var steps = MathF.Round((speed - MinPlaybackSpeed) / PlaybackSpeedStep);
    var nearestOnGrid = MinPlaybackSpeed + (steps * PlaybackSpeedStep);
    if (MathF.Abs(speed - nearestOnGrid) > 0.0001f)
    {
        error = $"'{fieldName}' must be in increments of {PlaybackSpeedStep}.";
        return false;
    }

    error = null;
    return true;
}

bool TryValidateNullablePlaybackSpeed(float? speed, string fieldName, out string? error)
{
    if (speed is { } value)
    {
        return TryValidatePlaybackSpeed(value, fieldName, out error);
    }

    error = null;
    return true;
}

settings.MapPut("/playback-speed", async (
    UpdatePlaybackSpeedRequest request,
    ClaimsPrincipal user,
    ISettingsService settingsService,
    CancellationToken ct) =>
{
    if (!TryValidatePlaybackSpeed(request.PlaybackSpeed, "playbackSpeed", out var error))
    {
        return Results.BadRequest(new { error });
    }

    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    var result = await settingsService.UpdatePlaybackSpeedAsync(userId, request.PlaybackSpeed, ct);
    return Results.Ok(result);
});

settings.MapPut("/shows/{showId}/playback-speed", async (
    string showId,
    UpdateShowPlaybackSpeedRequest request,
    ClaimsPrincipal user,
    ISettingsService settingsService,
    CancellationToken ct) =>
{
    if (!TryValidateNullablePlaybackSpeed(request.PlaybackSpeed, "playbackSpeed", out var error))
    {
        return Results.BadRequest(new { error });
    }

    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    var result = await settingsService.UpdateShowPlaybackSpeedAsync(userId, showId, request.PlaybackSpeed, ct);
    return Results.Ok(result);
});

// Upper bound is generous (a year) — it exists only to reject obviously-wrong input, not to
// model any real retention policy.
const int MaxAutoDeleteAfterDays = 365;

bool TryValidateAutoDeleteAfterDays(int days, string fieldName, out string? error)
{
    if (days < 1 || days > MaxAutoDeleteAfterDays)
    {
        error = $"'{fieldName}' must be between 1 and {MaxAutoDeleteAfterDays}.";
        return false;
    }

    error = null;
    return true;
}

settings.MapPut("/auto-delete", async (
    UpdateAutoDeleteRuleRequest request,
    ClaimsPrincipal user,
    ISettingsService settingsService,
    CancellationToken ct) =>
{
    if (!Enum.IsDefined(request.AutoDeleteRule))
    {
        return Results.BadRequest(new { error = "'autoDeleteRule' is not a valid value." });
    }

    // AutoDeleteAfterDays is only meaningful when AutoDeleteRule == AfterDays (UserSettings.cs's
    // own doc comment) — validating it unconditionally would force a client that only wants to
    // set rule=Never/AfterPlayed to also send some arbitrary-but-valid day count.
    if (request.AutoDeleteRule == AutoDeleteRule.AfterDays &&
        !TryValidateAutoDeleteAfterDays(request.AutoDeleteAfterDays, "autoDeleteAfterDays", out var error))
    {
        return Results.BadRequest(new { error });
    }

    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    var result = await settingsService.UpdateAutoDeleteRuleAsync(userId, request.AutoDeleteRule, request.AutoDeleteAfterDays, ct);
    return Results.Ok(result);
});

settings.MapPut("/auto-download", async (
    UpdateAutoDownloadNewEpisodesRequest request,
    ClaimsPrincipal user,
    ISettingsService settingsService,
    CancellationToken ct) =>
{
    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    var result = await settingsService.UpdateAutoDownloadNewEpisodesAsync(userId, request.AutoDownloadNewEpisodes, ct);
    return Results.Ok(result);
});

settings.MapPut("/shows/{showId}/auto-download", async (
    string showId,
    UpdateShowAutoDownloadNewEpisodesRequest request,
    ClaimsPrincipal user,
    ISettingsService settingsService,
    CancellationToken ct) =>
{
    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    var result = await settingsService.UpdateShowAutoDownloadNewEpisodesAsync(userId, showId, request.AutoDownloadNewEpisodes, ct);
    return Results.Ok(result);
});

settings.MapPut("/auto-add-up-next", async (
    UpdateAutoAddNewEpisodesToUpNextRequest request,
    ClaimsPrincipal user,
    ISettingsService settingsService,
    CancellationToken ct) =>
{
    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    var result = await settingsService.UpdateAutoAddNewEpisodesToUpNextAsync(userId, request.AutoAddNewEpisodesToUpNext, ct);
    return Results.Ok(result);
});

settings.MapPut("/shows/{showId}/auto-add-up-next", async (
    string showId,
    UpdateShowAutoAddNewEpisodesToUpNextRequest request,
    ClaimsPrincipal user,
    ISettingsService settingsService,
    CancellationToken ct) =>
{
    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    var result = await settingsService.UpdateShowAutoAddNewEpisodesToUpNextAsync(userId, showId, request.AutoAddNewEpisodesToUpNext, ct);
    return Results.Ok(result);
});

settings.MapPut("/up-next-insert-position", async (
    UpdateUpNextInsertPositionRequest request,
    ClaimsPrincipal user,
    ISettingsService settingsService,
    CancellationToken ct) =>
{
    if (!Enum.IsDefined(request.UpNextInsertPosition))
    {
        return Results.BadRequest(new { error = "'upNextInsertPosition' is not a valid value." });
    }

    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    var result = await settingsService.UpdateUpNextInsertPositionAsync(userId, request.UpNextInsertPosition, ct);
    return Results.Ok(result);
});

settings.MapPut("/smart-speed", async (
    UpdateSmartSpeedRequest request,
    ClaimsPrincipal user,
    ISettingsService settingsService,
    CancellationToken ct) =>
{
    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    var result = await settingsService.UpdateSmartSpeedAsync(userId, request.SmartSpeed, ct);
    return Results.Ok(result);
});

settings.MapPut("/shows/{showId}/smart-speed", async (
    string showId,
    UpdateShowSmartSpeedRequest request,
    ClaimsPrincipal user,
    ISettingsService settingsService,
    CancellationToken ct) =>
{
    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    var result = await settingsService.UpdateShowSmartSpeedAsync(userId, showId, request.SmartSpeed, ct);
    return Results.Ok(result);
});

settings.MapPut("/notifications", async (
    UpdateNotificationsEnabledRequest request,
    ClaimsPrincipal user,
    ISettingsService settingsService,
    CancellationToken ct) =>
{
    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    var result = await settingsService.UpdateNotificationsEnabledAsync(userId, request.NotificationsEnabled, ct);
    return Results.Ok(result);
});

settings.MapPut("/shows/{showId}/notifications", async (
    string showId,
    UpdateShowNotificationsEnabledRequest request,
    ClaimsPrincipal user,
    ISettingsService settingsService,
    CancellationToken ct) =>
{
    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    var result = await settingsService.UpdateShowNotificationsEnabledAsync(userId, showId, request.NotificationsEnabled, ct);
    return Results.Ok(result);
});

// Upper bound is generous (12 hours) — it exists only to reject obviously-wrong input (e.g. a
// negative or zero duration, which would fire the timer either instantly or never), not to model
// any real limit on how long a listening session can run.
const int MaxSleepTimerDefaultDurationMinutes = 720;

bool TryValidateSleepTimerDefaultDurationMinutes(int minutes, string fieldName, out string? error)
{
    if (minutes < 1 || minutes > MaxSleepTimerDefaultDurationMinutes)
    {
        error = $"'{fieldName}' must be between 1 and {MaxSleepTimerDefaultDurationMinutes}.";
        return false;
    }

    error = null;
    return true;
}

// Shared by the sync endpoint above (where the field is nullable — see UserSettingsChange's own
// doc comment) and the field-specific PUT below (where it's required) so both routes reject the
// same out-of-range values instead of only the PUT catching them.
bool TryValidateNullableSleepTimerDefaultDurationMinutes(int? minutes, string fieldName, out string? error)
{
    if (minutes is { } value)
    {
        return TryValidateSleepTimerDefaultDurationMinutes(value, fieldName, out error);
    }

    error = null;
    return true;
}

settings.MapPut("/sleep-timer-default-duration", async (
    UpdateSleepTimerDefaultDurationRequest request,
    ClaimsPrincipal user,
    ISettingsService settingsService,
    CancellationToken ct) =>
{
    if (!TryValidateSleepTimerDefaultDurationMinutes(
            request.SleepTimerDefaultDurationMinutes, "sleepTimerDefaultDurationMinutes", out var error))
    {
        return Results.BadRequest(new { error });
    }

    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    var result = await settingsService.UpdateSleepTimerDefaultDurationAsync(
        userId, request.SleepTimerDefaultDurationMinutes, ct);
    return Results.Ok(result);
});

app.Run();
