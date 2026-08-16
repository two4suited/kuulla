using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;
using Kuulla.Api.Services;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.IdentityModel.Tokens;

var builder = WebApplication.CreateBuilder(args);

builder.AddServiceDefaults();
builder.AddAzureCosmosClient("kuulladb");
builder.AddAzureCosmosContainer("users");
builder.AddRedisClient("redis");

builder.Services.AddScoped<IUserService, UserService>();

var googleClientId = builder.Configuration["Google:ClientId"];
var googleIosClientId = builder.Configuration["Google:IosClientId"];
var googleAudiences = new[] { googleClientId, googleIosClientId }
    .Where(audience => !string.IsNullOrEmpty(audience))
    .ToArray();

if (googleAudiences.Length == 0)
{
    throw new InvalidOperationException(
        "No Google OAuth client IDs configured. Set 'Google:ClientId' and/or 'Google:IosClientId' " +
        "so JWT bearer authentication has a valid audience to check tokens against.");
}

builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddJwtBearer(options =>
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
            OnTokenValidated = async context =>
            {
                var principal = context.Principal!;
                var subject = principal.FindFirstValue(JwtRegisteredClaimNames.Sub);
                var email = principal.FindFirstValue(JwtRegisteredClaimNames.Email);
                if (subject is null || email is null)
                {
                    context.Fail("Google ID token is missing required 'sub' or 'email' claims.");
                    return;
                }

                var name = principal.FindFirstValue("name");
                var pictureUrl = principal.FindFirstValue("picture");

                var userService = context.HttpContext.RequestServices.GetRequiredService<IUserService>();
                await userService.GetOrCreateUserAsync(subject, email, name, pictureUrl, context.HttpContext.RequestAborted);
            },
        };
    });
builder.Services.AddAuthorization();

var app = builder.Build();

app.MapDefaultEndpoints();

app.UseAuthentication();
app.UseAuthorization();

app.MapGet("/health", () => Results.Ok(new { status = "healthy" }));

app.MapGet("/me", (ClaimsPrincipal user) => Results.Ok(new
{
    Subject = user.FindFirstValue(JwtRegisteredClaimNames.Sub),
    Email = user.FindFirstValue(JwtRegisteredClaimNames.Email),
    Name = user.FindFirstValue("name"),
    PictureUrl = user.FindFirstValue("picture"),
})).RequireAuthorization();

app.Run();
