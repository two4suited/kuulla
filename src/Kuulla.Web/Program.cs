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
builder.Services.AddScoped<TokenProvider>();

builder.Services.AddAuthentication(CookieAuthenticationDefaults.AuthenticationScheme)
    .AddCookie()
    .AddGoogle(options =>
    {
        options.ClientId = builder.Configuration["Authentication:Google:ClientId"]!;
        options.ClientSecret = builder.Configuration["Authentication:Google:ClientSecret"]!;
        options.SaveTokens = true;
        // SaveTokens only persists access_token/refresh_token/token_type/expires_at; the OAuth
        // handler never stores id_token, so it has to be pulled off the raw token response here.
        options.Events.OnCreatingTicket = context =>
        {
            var idToken = context.TokenResponse.Response!.RootElement.GetProperty("id_token").GetString();
            if (idToken is not null)
            {
                var tokens = context.Properties.GetTokens().ToList();
                tokens.Add(new AuthenticationToken { Name = "id_token", Value = idToken });
                context.Properties.StoreTokens(tokens);
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

if (app.Environment.IsDevelopment())
{
    // Local-testing-only (issue #48): signs the browser in with a cookie identity backed by a
    // token from the API's dev-only /dev/test-token endpoint, instead of the real Google OAuth
    // challenge, so the app can be exercised locally without Google credentials configured.
    app.MapGet("/Account/LoginTest", async (string? returnUrl, IHttpClientFactory httpClientFactory, HttpContext context) =>
    {
        var apiClient = httpClientFactory.CreateClient("api");
        var response = await apiClient.PostAsync("/dev/test-token", content: null);
        response.EnsureSuccessStatusCode();
        var payload = await response.Content.ReadFromJsonAsync<JsonElement>();
        var idToken = payload.GetProperty("token").GetString()!;

        var identity = new ClaimsIdentity(
        [
            new Claim(ClaimTypes.NameIdentifier, "local-test-user"),
            new Claim(ClaimTypes.Email, "test@local.kuulla.dev"),
            new Claim(ClaimTypes.Name, "Local Test User"),
        ], CookieAuthenticationDefaults.AuthenticationScheme);

        var properties = new AuthenticationProperties { RedirectUri = returnUrl ?? "/" };
        properties.StoreTokens([new AuthenticationToken { Name = "id_token", Value = idToken }]);

        await context.SignInAsync(CookieAuthenticationDefaults.AuthenticationScheme, new ClaimsPrincipal(identity), properties);
        return Results.LocalRedirect(returnUrl ?? "/");
    });
}

app.Run();
