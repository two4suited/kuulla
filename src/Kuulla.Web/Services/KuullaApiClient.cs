using System.Net.Http.Headers;
using Microsoft.AspNetCore.Components.Authorization;

namespace Kuulla.Web.Services;

// IHttpClientFactory caches the "api" handler pipeline across circuits for HandlerLifetime,
// so a DelegatingHandler resolved via AddHttpMessageHandler would capture one user's scoped
// AuthenticationStateProvider and leak it to other users' requests. Attaching the header per
// call on a freshly-created HttpClient instance keeps the token scoped to the current circuit.
public class KuullaApiClient(IHttpClientFactory httpClientFactory, AuthenticationStateProvider authenticationStateProvider)
{
    public async Task<HttpClient> CreateClientAsync()
    {
        var client = httpClientFactory.CreateClient("api");

        var authState = await authenticationStateProvider.GetAuthenticationStateAsync();
        var idToken = authState.User.FindFirst(TokenClaimTypes.IdToken)?.Value;
        if (idToken is not null)
        {
            client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", idToken);
        }

        return client;
    }
}
