using System.Net;
using System.Net.Http.Json;

namespace Kuulla.Web.Tests;

public class TestHttpMessageHandler : HttpMessageHandler
{
    private readonly Func<HttpRequestMessage, HttpResponseMessage> handler;

    public TestHttpMessageHandler(Func<HttpRequestMessage, HttpResponseMessage> handler)
    {
        this.handler = handler;
    }

    public static TestHttpMessageHandler Json<T>(T value, HttpStatusCode statusCode = HttpStatusCode.OK) =>
        new(_ => new HttpResponseMessage(statusCode) { Content = JsonContent.Create(value) });

    public static TestHttpMessageHandler Status(HttpStatusCode statusCode) =>
        new(_ => new HttpResponseMessage(statusCode));

    // Lets one test handler delegate unmatched requests to another (composition without
    // re-declaring every shared route).
    public HttpResponseMessage Invoke(HttpRequestMessage request) => handler(request);

    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
        Task.FromResult(handler(request));
}
