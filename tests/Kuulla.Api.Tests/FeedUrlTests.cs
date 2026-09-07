using Kuulla.Core.Services;

namespace Kuulla.Api.Tests;

public class FeedUrlTests
{
    [Theory]
    [InlineData("https://example.com/feed", "https://example.com/feed")]
    [InlineData("http://example.com/feed", "https://example.com/feed")] // http folds onto https
    [InlineData("https://EXAMPLE.com/feed", "https://example.com/feed")] // host lower-cased
    [InlineData("https://example.com/feed/", "https://example.com/feed")] // trailing slash dropped
    [InlineData("https://example.com/feed///", "https://example.com/feed")] // repeated trailing slashes
    [InlineData("https://example.com:443/feed", "https://example.com/feed")] // default https port
    [InlineData("http://example.com:80/feed", "https://example.com/feed")] // default http port
    [InlineData("  https://example.com/feed  ", "https://example.com/feed")] // surrounding whitespace
    [InlineData("https://example.com", "https://example.com")] // bare root, no path
    [InlineData("https://example.com/", "https://example.com")] // bare root with slash
    public void Normalize_CanonicalisesEquivalentForms(string input, string expected)
    {
        Assert.Equal(expected, FeedUrl.Normalize(input));
    }

    [Fact]
    public void Normalize_KeepsNonDefaultPort()
    {
        Assert.Equal("https://example.com:8080/feed", FeedUrl.Normalize("http://example.com:8080/feed/"));
    }

    [Fact]
    public void Normalize_PreservesQueryString()
    {
        Assert.Equal("https://example.com/feed?format=rss", FeedUrl.Normalize("https://example.com/feed?format=rss"));
        Assert.NotEqual(
            FeedUrl.Normalize("https://example.com/feed"),
            FeedUrl.Normalize("https://example.com/feed?format=rss"));
    }

    [Theory]
    [InlineData("https://example.com/feed-a", "https://example.com/feed-b")] // different paths
    [InlineData("https://a.example.com/feed", "https://b.example.com/feed")] // different hosts
    [InlineData("https://example.com/Feed", "https://example.com/feed")] // path is case-sensitive
    public void Normalize_KeepsDistinctFeedsDistinct(string a, string b)
    {
        Assert.NotEqual(FeedUrl.Normalize(a), FeedUrl.Normalize(b));
    }

    [Fact]
    public void Normalize_ReturnsInputTrimmedWhenNotAnHttpUrl()
    {
        Assert.Equal("not a url", FeedUrl.Normalize("  not a url  "));
        Assert.Equal("ftp://example.com/feed", FeedUrl.Normalize("ftp://example.com/feed"));
    }
}
