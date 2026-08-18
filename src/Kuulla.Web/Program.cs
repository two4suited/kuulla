using System.Security.Claims;
using System.Text.Json;
using Kuulla.Web.Components;
using Kuulla.Web.Services;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.Authentication.Google;

var builder = WebApplication.CreateBuilder(args);

builder.AddServiceDefaults();

builder.Services.AddRazorComponents()
    .AddInteractiveServerComponents();

builder.Services.AddCascadingAuthenticationState();

builder.Services.AddAuthentication(CookieAuthenticationDefaults.AuthenticationScheme)
    .AddCookie()
    .AddGoogle(options =>
    {
        options.ClientId = builder.Configuration["Authentication:Google:ClientId"]!;
        options.ClientSecret = builder.Configuration["Authentication:Google:ClientSecret"]!;
        options.SaveTokens = true;
        // SaveTokens only persists access_token/refresh_token/token_type/expires_at; the OAuth
        // handler never stores id_token, so it has to be pulled off the raw token response here.
        // It's added as a claim (not just AuthenticationProperties/StoreTokens) so it flows via
        // the cascading AuthenticationState into every interactive circuit — including pages
        // that opt out of prerendering, where HttpContext.GetTokenAsync is never reachable.
        options.Events.OnCreatingTicket = context =>
        {
            if (context.TokenResponse.Response?.RootElement.TryGetProperty("id_token", out var idTokenProperty) is true
                && idTokenProperty.GetString() is { } idToken)
            {
                context.Identity?.AddClaim(new Claim(TokenClaimTypes.IdToken, idToken));
            }

            return Task.CompletedTask;
        };
    });
builder.Services.AddAuthorization();

builder.Services.AddHttpClient("api", client =>
{
    client.BaseAddress = new Uri("https+http://api");
});
builder.Services.AddScoped<KuullaApiClient>();
builder.Services.AddScoped<PodcastCatalogClient>();
builder.Services.AddScoped<SubscriptionClient>();
builder.Services.AddScoped<SettingsClient>();
builder.Services.AddScoped<EpisodeStateClient>();

var app = builder.Build();

app.MapDefaultEndpoints();

if (!app.Environment.IsDevelopment())
{
    app.UseExceptionHandler("/Error", createScopeForErrors: true);
    app.UseHsts();
}

app.UseHttpsRedirection();

app.UseAuthentication();
app.UseAuthorization();

app.UseAntiforgery();

app.MapStaticAssets();
app.MapRazorComponents<App>()
    .AddInteractiveServerRenderMode();

app.MapGet("/Account/Login", (string? returnUrl) =>
{
    var properties = new AuthenticationProperties { RedirectUri = returnUrl ?? "/" };
    return Results.Challenge(properties, [GoogleDefaults.AuthenticationScheme]);
});

app.MapPost("/Account/Logout", async (HttpContext context) =>
{
    await context.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme);
    return Results.LocalRedirect("/");
});

#if DEBUG
if (app.Environment.IsDevelopment())
{
    // Local-testing-only (issue #48): signs the browser in with a cookie identity backed by a
    // token from the API's dev-only /dev/test-token endpoint, instead of the real Google OAuth
    // challenge, so the app can be exercised locally without Google credentials configured.
    // POST (mirroring /Account/Logout below) rather than GET, and antiforgery-protected via the
    // form in LoginDisplay.razor, so a state-changing sign-in can't be triggered cross-site
    // (e.g. from an <img> tag on another page). Compiled out of Release builds entirely,
    // regardless of ASPNETCORE_ENVIRONMENT.
    app.MapPost("/Account/LoginTest", async (IHttpClientFactory httpClientFactory, HttpContext context) =>
    {
        var apiClient = httpClientFactory.CreateClient("api");
        var response = await apiClient.PostAsync("/dev/test-token", content: null, context.RequestAborted);
        response.EnsureSuccessStatusCode();
        var payload = await response.Content.ReadFromJsonAsync<JsonElement>(cancellationToken: context.RequestAborted);
        var idToken = payload.GetProperty("token").GetString()!;

        var identity = new ClaimsIdentity(
        [
            new Claim(ClaimTypes.NameIdentifier, "local-test-user"),
            new Claim(ClaimTypes.Email, "test@local.kuulla.dev"),
            new Claim(ClaimTypes.Name, "Local Test User"),
            new Claim(TokenClaimTypes.IdToken, idToken),
        ], CookieAuthenticationDefaults.AuthenticationScheme);

        await context.SignInAsync(CookieAuthenticationDefaults.AuthenticationScheme, new ClaimsPrincipal(identity));
        return Results.LocalRedirect("/");
    });
}
#endif

app.Run();
