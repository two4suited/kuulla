using System.Net;
using Kuulla.Api.Models;
using Kuulla.Api.Services;
using Microsoft.Extensions.Logging.Abstractions;
using Moq;
using Newtonsoft.Json;
using StackExchange.Redis;

namespace Kuulla.Api.Tests;

public class TranscriptServiceTests
{
    private const string TranscriptUrl = "https://feed.example/ep1-transcript.json";
    private static readonly IPAddress PublicTestAddress = IPAddress.Parse("93.184.216.34");

    private readonly Mock<IConnectionMultiplexer> _redis = new();
    private readonly Mock<IDatabase> _database = new();

    public TranscriptServiceTests()
    {
        _redis.Setup(r => r.GetDatabase(It.IsAny<int>(), It.IsAny<object>())).Returns(_database.Object);
        _database.Setup(d => d.StringGetAsync(It.IsAny<RedisKey>(), It.IsAny<CommandFlags>())).ReturnsAsync(RedisValue.Null);
    }

    private TranscriptService MakeSut(
        Func<Uri, CancellationToken, Task<HttpResponseMessage>> send,
        Func<string, CancellationToken, Task<IPAddress[]>>? hostResolver = null)
    {
        var fetcher = new PublicResourceFetcher(
            NullLogger<PublicResourceFetcher>.Instance,
            hostResolver ?? ((_, _) => Task.FromResult(new[] { PublicTestAddress })),
            send);
        return new TranscriptService(fetcher, _redis.Object, NullLogger<TranscriptService>.Instance);
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
    public async Task GetTranscriptAsync_FetchesParsesAndCaches()
    {
        const string json = """{ "segments": [ { "startTime": 0, "endTime": 1.5, "body": "hi" } ] }""";
        var sut = MakeSut((_, _) => Task.FromResult(Ok(json)));

        var document = await sut.GetTranscriptAsync(TranscriptUrl, "application/json", CancellationToken.None);

        var segment = Assert.Single(document!.Segments);
        Assert.Equal(TimeSpan.Zero, segment.StartTime);
        Assert.Equal(TimeSpan.FromSeconds(1.5), segment.EndTime);
        Assert.Equal("hi", segment.Text);
        Assert.Equal("application/json", document.SourceType);

        var set = Assert.Single(_database.Invocations, i => i.Method.Name == nameof(IDatabaseAsync.StringSetAsync));
        Assert.StartsWith("transcript:v1:", (string)(RedisKey)set.Arguments[0]!);
        Assert.Equal((Expiration)TimeSpan.FromDays(7), (Expiration)set.Arguments[2]!);
    }

    [Fact]
    public async Task GetTranscriptAsync_ReturnsCachedDocumentWithoutFetching()
    {
        var cached = new TranscriptDocument("text/vtt", [new TranscriptSegment(TimeSpan.FromSeconds(3), null, "cached")]);
        _database
            .Setup(d => d.StringGetAsync(It.IsAny<RedisKey>(), It.IsAny<CommandFlags>()))
            .ReturnsAsync(new RedisValue(JsonConvert.SerializeObject(cached)));
        var fetched = false;
        var sut = MakeSut((_, _) => { fetched = true; return Task.FromResult(Ok("{}")); });

        var document = await sut.GetTranscriptAsync(TranscriptUrl, "text/vtt", CancellationToken.None);

        Assert.Equal("cached", Assert.Single(document!.Segments).Text);
        Assert.False(fetched);
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
    public async Task GetTranscriptAsync_NegativeCachesBrieflyWhenNoSegmentsParsed()
    {
        var sut = MakeSut((_, _) => Task.FromResult(Ok("nothing parseable here")));

        var document = await sut.GetTranscriptAsync(TranscriptUrl, "text/plain", CancellationToken.None);

        Assert.Null(document);
        var set = Assert.Single(_database.Invocations, i => i.Method.Name == nameof(IDatabaseAsync.StringSetAsync));
        Assert.Equal((Expiration)TimeSpan.FromMinutes(15), (Expiration)set.Arguments[2]!);
    }

    [Fact]
    public async Task GetTranscriptAsync_TreatsCachedEmptyDocumentAsNoTranscript()
    {
        var negative = new TranscriptDocument(null, []);
        _database
            .Setup(d => d.StringGetAsync(It.IsAny<RedisKey>(), It.IsAny<CommandFlags>()))
            .ReturnsAsync(new RedisValue(JsonConvert.SerializeObject(negative)));
        var fetched = false;
        var sut = MakeSut((_, _) => { fetched = true; return Task.FromResult(Ok("{}")); });

        Assert.Null(await sut.GetTranscriptAsync(TranscriptUrl, null, CancellationToken.None));
        Assert.False(fetched);
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
