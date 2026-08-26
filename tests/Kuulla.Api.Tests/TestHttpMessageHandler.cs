using System.Net;
using System.Net.Http.Json;

namespace Kuulla.Api.Tests;

public class TestHttpMessageHandler(Func<HttpRequestMessage, HttpResponseMessage> handler) : HttpMessageHandler
{
    public static TestHttpMessageHandler Json<T>(T value, HttpStatusCode statusCode = HttpStatusCode.OK) =>
        new(_ => new HttpResponseMessage(statusCode) { Content = JsonContent.Create(value) });

    public static TestHttpMessageHandler Routed(Func<Uri, HttpResponseMessage> route) =>
        new(request => route(request.RequestUri!));

    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult(handler(request));
    }
}
