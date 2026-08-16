using System.Net.Http.Headers;

namespace Kuulla.Web.Services;

// IHttpClientFactory caches the "api" handler pipeline across circuits for HandlerLifetime,
// so a DelegatingHandler resolved via AddHttpMessageHandler would capture one user's scoped
// TokenProvider and leak it to other users' requests. Attaching the header per call on a
// freshly-created HttpClient instance keeps the token scoped to the current circuit.
public class KuullaApiClient(IHttpClientFactory httpClientFactory, TokenProvider tokenProvider)
{
    public HttpClient CreateClient()
    {
        var client = httpClientFactory.CreateClient("api");

        if (tokenProvider.IdToken is { } idToken)
        {
            client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", idToken);
        }

        return client;
    }
}
