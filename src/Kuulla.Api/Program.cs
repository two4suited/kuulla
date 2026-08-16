using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;
using System.Security.Cryptography;
using Kuulla.Api.Services;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.IdentityModel.Tokens;

var builder = WebApplication.CreateBuilder(args);

builder.AddServiceDefaults();
builder.AddAzureCosmosClient("kuulladb");
builder.AddAzureCosmosContainer("users");
builder.AddKeyedAzureCosmosContainer("shows");
builder.AddKeyedAzureCosmosContainer("episodes");
builder.AddRedisClient("redis");

builder.Services.AddScoped<IUserService, UserService>();
builder.Services.AddScoped<IShowService, ShowService>();
builder.Services.AddScoped<IEpisodeService, EpisodeService>();
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
            IssuerSigningKey = localTestSigningKey,
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
    // Local-testing-only (issue #48): mints a token that satisfies the same validation the
    // Google scheme applies (issuer, signature, sub/email claims) so Web/iOS can exercise
    // authenticated flows without a real Google sign-in. Never registered outside Development,
    // and compiled out of Release builds entirely regardless of ASPNETCORE_ENVIRONMENT.
    app.MapPost("/dev/test-token", () =>
    {
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

app.Run();
