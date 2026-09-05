using System.Net;
using Kuulla.Api.Services;
using Microsoft.Extensions.Logging.Abstractions;

namespace Kuulla.Api.Tests;

public class TranscriptServiceTests
{
    private const string TranscriptUrl = "https://feed.example/ep1-transcript.json";
    private static readonly IPAddress PublicTestAddress = IPAddress.Parse("93.184.216.34");

    private static TranscriptService MakeSut(
        Func<Uri, CancellationToken, Task<HttpResponseMessage>> send,
        Func<string, CancellationToken, Task<IPAddress[]>>? hostResolver = null)
    {
        var fetcher = new PublicResourceFetcher(
            NullLogger<PublicResourceFetcher>.Instance,
            hostResolver ?? ((_, _) => Task.FromResult(new[] { PublicTestAddress })),
            send);
        return new TranscriptService(fetcher, NullLogger<TranscriptService>.Instance);
    }

    private static HttpResponseMessage Ok(string body, string? contentType = null)
    {
        var response = new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(body) };
        if (contentType is not null)
        {
            response.Content.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue(contentType);
        }

        return response;
    }

    [Fact]
    public async Task GetTranscriptAsync_FetchesAndParses()
    {
        const string json = """{ "segments": [ { "startTime": 0, "endTime": 1.5, "body": "hi" } ] }""";
        var sut = MakeSut((_, _) => Task.FromResult(Ok(json)));

        var document = await sut.GetTranscriptAsync(TranscriptUrl, "application/json", CancellationToken.None);

        var segment = Assert.Single(document!.Segments);
        Assert.Equal(TimeSpan.Zero, segment.StartTime);
        Assert.Equal(TimeSpan.FromSeconds(1.5), segment.EndTime);
        Assert.Equal("hi", segment.Text);
        Assert.Equal("application/json", document.SourceType);
    }

    [Fact]
    public async Task GetTranscriptAsync_DetectsFormatWhenTypeMissing()
    {
        const string srt = "1\n00:00:02,000 --> 00:00:04,000\nsniffed";
        var sut = MakeSut((_, _) => Task.FromResult(Ok(srt)));

        var document = await sut.GetTranscriptAsync(TranscriptUrl, null, CancellationToken.None);

        Assert.Equal("sniffed", Assert.Single(document!.Segments).Text);
    }

    [Fact]
    public async Task GetTranscriptAsync_ReturnsNullWhenNoSegmentsParsed()
    {
        var sut = MakeSut((_, _) => Task.FromResult(Ok("nothing parseable here")));

        var document = await sut.GetTranscriptAsync(TranscriptUrl, "text/plain", CancellationToken.None);

        Assert.Null(document);
    }

    [Fact]
    public async Task GetTranscriptAsync_ReturnsNullWhenUrlRejectedBySsrfGuard()
    {
        var fetched = false;
        var sut = MakeSut(
            (_, _) => { fetched = true; return Task.FromResult(Ok("{}")); },
            hostResolver: (_, _) => Task.FromResult(new[] { IPAddress.Parse("10.0.0.5") }));

        var document = await sut.GetTranscriptAsync("https://internal.example/t.json", "application/json", CancellationToken.None);

        Assert.Null(document);
        Assert.False(fetched);
    }

    [Fact]
    public async Task GetTranscriptAsync_ReturnsNullWhenFetchFails()
    {
        var sut = MakeSut((_, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.NotFound)));

        Assert.Null(await sut.GetTranscriptAsync(TranscriptUrl, "application/json", CancellationToken.None));
    }
}
