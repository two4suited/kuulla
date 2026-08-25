using Kuulla.Api.Models;
using Microsoft.Azure.Cosmos;
using Moq;

namespace Kuulla.Api.Tests;

// Container, FeedIterator<T>, ItemResponse<T> and FeedResponse<T> are all abstract classes
// with protected parameterless constructors specifically so they can be mocked (per the SDK's
// own XML docs: "Create a[n] ItemResponse/FeedResponse as a no-op for mock testing").
internal static class CosmosTestHelpers
{
    // Defaults to a non-null ETag — a real Cosmos document read/write always carries one, so a
    // test standing in for "existing document" shouldn't need to opt into that explicitly. Tests
    // that specifically exercise ETag-based concurrency (a stale/matching/mismatched value) pass
    // their own.
    public static ItemResponse<T> ItemResponse<T>(T resource, string etag = "etag")
    {
        var mock = new Mock<ItemResponse<T>>();
        mock.SetupGet(r => r.Resource).Returns(resource);
        mock.SetupGet(r => r.ETag).Returns(etag);
        return mock.Object;
    }

    public static FeedIterator<T> FeedIterator<T>(IReadOnlyList<T> items) => FeedIterator<T>(pages: [items]);

    // Cycles through one page per ReadNextAsync call, so tests that need to prove a
    // `while (iterator.HasMoreResults)` loop actually aggregates across multiple pages
    // (rather than just returning early after the first) can pass 2+ pages here.
    public static FeedIterator<T> FeedIterator<T>(params IReadOnlyList<IReadOnlyList<T>> pages)
    {
        var mock = new Mock<FeedIterator<T>>();
        var index = 0;
        mock.SetupGet(i => i.HasMoreResults).Returns(() => index < pages.Count);
        mock.Setup(i => i.ReadNextAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(() => FeedResponse(pages[index++]));
        return mock.Object;
    }

    public static FeedResponse<T> FeedResponse<T>(IReadOnlyList<T> items)
    {
        var mock = new Mock<FeedResponse<T>>();
        mock.Setup(r => r.GetEnumerator()).Returns(() => items.GetEnumerator());
        mock.As<System.Collections.IEnumerable>().Setup(r => r.GetEnumerator()).Returns(() => items.GetEnumerator());
        return mock.Object;
    }

    public static CosmosException NotFound() =>
        new("not found", System.Net.HttpStatusCode.NotFound, 0, string.Empty, 0);

    public static CosmosException Conflict() =>
        new("conflict", System.Net.HttpStatusCode.Conflict, 0, string.Empty, 0);

    public static CosmosException PreconditionFailed() =>
        new("precondition failed", System.Net.HttpStatusCode.PreconditionFailed, 0, string.Empty, 0);

    // Show.FeedUrl is non-nullable, matching production (ItunesPodcastDirectoryClient always
    // sets it) — pass feedUrl: "" for tests that need a show with no feed, mirroring how
    // ShowService/EpisodeService already treat "missing feed" via string.IsNullOrEmpty checks.
    public static Show MakeShow(
        string id = "show-1",
        string? description = null,
        string feedUrl = "https://feed.example/rss") =>
        new(id, "Title", "Author", feedUrl, "https://art.example/art.png", description, ["Tech"]);
}
