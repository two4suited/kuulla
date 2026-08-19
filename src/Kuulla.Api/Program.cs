using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;
using System.Security.Cryptography;
using Kuulla.Api.Models;
using Kuulla.Api.Services;
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
builder.AddRedisClient("redis");

builder.Services.AddScoped<IUserService, UserService>();
builder.Services.AddScoped<IShowService, ShowService>();
builder.Services.AddScoped<IEpisodeService, EpisodeService>();
builder.Services.AddScoped<ISubscriptionService, SubscriptionService>();
builder.Services.AddScoped<ISettingsService, SettingsService>();
builder.Services.AddScoped<IEpisodeStateService, EpisodeStateService>();
builder.Services.AddScoped<IPlaylistService, PlaylistService>();
builder.Services.AddHttpClient<IPodcastDirectoryClient, ItunesPodcastDirectoryClient>(client =>
{
    client.BaseAddress = new Uri("https://itunes.apple.com/");
});
builder.Services.AddHttpClient<IPodcastFeedClient, PodcastFeedClient>();

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
    app.MapPost("/dev/test-token", (HttpContext context) =>
    {
        if (!IsLoopbackCaller(context))
        {
            return Results.StatusCode(StatusCodes.Status403Forbidden);
        }

        var claims = new[]
        {
            new Claim(JwtRegisteredClaimNames.Sub, "local-test-user"),
            new Claim(JwtRegisteredClaimNames.Email, "test@local.kuulla.dev"),
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
    CancellationToken ct) =>
{
    if (string.IsNullOrWhiteSpace(request.ShowId))
    {
        return Results.BadRequest(new { error = "'showId' is required." });
    }

    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    var subscription = await subscriptionService.SubscribeAsync(userId, request.ShowId, ct);
    return subscription is not null ? Results.Ok(subscription) : Results.NotFound();
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

episodeState.MapPut("/{id}/state", async (
    string id,
    UpdateEpisodeStateRequest request,
    ClaimsPrincipal user,
    IEpisodeStateService episodeStateService,
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
    return Results.Ok(result);
});

var playlists = app.MapGroup("/api/playlists").RequireAuthorization();

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

    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    var playlist = await playlistService.CreatePlaylistAsync(userId, request.Name, ct);
    return Results.Ok(playlist);
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

    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    var playlist = await playlistService.RenamePlaylistAsync(userId, id, request.Name, ct);
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
    }

    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    var result = await playlistService.SyncAsync(
        userId, request.DeviceId, request.LastSyncedAt, request.LocalHash, changes, ct);
    return Results.Ok(result);
});

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
    CancellationToken ct) =>
{
    if (!Enum.IsDefined(request.UnlistenedEpisodeCount))
    {
        return Results.BadRequest(new { error = "'unlistenedEpisodeCount' is not a valid value." });
    }

    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    var result = await settingsService.UpdateUnlistenedEpisodeCountAsync(userId, request.UnlistenedEpisodeCount, ct);
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
    CancellationToken ct) =>
{
    if (request.UnlistenedEpisodeCount is { } value && !Enum.IsDefined(value))
    {
        return Results.BadRequest(new { error = "'unlistenedEpisodeCount' is not a valid value." });
    }

    var userId = user.FindFirstValue(JwtRegisteredClaimNames.Sub)!;
    var result = await settingsService.UpdateShowUnlistenedEpisodeCountAsync(userId, showId, request.UnlistenedEpisodeCount, ct);
    return Results.Ok(result);
});

app.Run();
