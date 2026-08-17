namespace Kuulla.Web.Services;

public static class TokenClaimTypes
{
    // Carries the Google/dev-test ID token as a claim on the ClaimsPrincipal so it flows through
    // the cascading AuthenticationState into every interactive circuit, including pages that opt
    // out of prerendering (where HttpContext.GetTokenAsync is never reachable).
    public const string IdToken = "urn:kuulla:id_token";
}
