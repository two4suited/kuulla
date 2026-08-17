using Kuulla.Api.Models;
using Microsoft.Azure.Cosmos;
using Moq;

namespace Kuulla.Api.Tests;

// Container, FeedIterator<T>, ItemResponse<T> and FeedResponse<T> are all abstract classes
// with protected parameterless constructors specifically so they can be mocked (per the SDK's
// own XML docs: "Create a[n] ItemResponse/FeedResponse as a no-op for mock testing").
internal static class CosmosTestHelpers
{
    public static ItemResponse<T> ItemResponse<T>(T resource)
    {
        var mock = new Mock<ItemResponse<T>>();
        mock.SetupGet(r => r.Resource).Returns(resource);
        return mock.Object;
    }

    public static FeedIterator<T> FeedIterator<T>(IReadOnlyList<T> items)
    {
        var mock = new Mock<FeedIterator<T>>();
        var consumed = false;
        mock.SetupGet(i => i.HasMoreResults).Returns(() => !consumed);
        mock.Setup(i => i.ReadNextAsync(It.IsAny<CancellationToken>()))
            .ReturnsAsync(() =>
            {
                consumed = true;
                return FeedResponse(items);
            });
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

    public static Show MakeShow(
        string id = "show-1",
        string? description = null,
        string? feedUrl = "https://feed.example/rss") =>
        new(id, "Title", "Author", feedUrl!, "https://art.example/art.png", description, ["Tech"]);
}
