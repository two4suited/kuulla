using Kuulla.Web.Models;
using Kuulla.Web.Services;

namespace Kuulla.Web.Tests.Services;

public class SubscriptionSortingTests
{
    private static Subscription Sub(
        string id, string title, DateTimeOffset? subscribedAt = null, DateTimeOffset? latestEpisodePublishedAt = null) =>
        new(id, id, title, "Author", null, subscribedAt ?? DateTimeOffset.UnixEpoch, latestEpisodePublishedAt);

    [Fact]
    public void Title_OrdersCaseInsensitiveAscending()
    {
        var subs = new[] { Sub("1", "zebra"), Sub("2", "Apple"), Sub("3", "mango") };

        var sorted = SubscriptionSorting.Sort(subs, SubscriptionSortOrder.Title);

        Assert.Equal(["2", "3", "1"], sorted.Select(s => s.Id));
    }

    [Fact]
    public void Manual_FallsBackToTitleForNow()
    {
        var subs = new[] { Sub("1", "zebra"), Sub("2", "Apple") };

        Assert.Equal(["2", "1"], SubscriptionSorting.Sort(subs, SubscriptionSortOrder.Manual).Select(s => s.Id));
    }

    [Fact]
    public void RecentlyAdded_OrdersNewestFirst()
    {
        var subs = new[]
        {
            Sub("old", "A", subscribedAt: new DateTimeOffset(2026, 1, 1, 0, 0, 0, TimeSpan.Zero)),
            Sub("new", "B", subscribedAt: new DateTimeOffset(2026, 3, 1, 0, 0, 0, TimeSpan.Zero)),
            Sub("mid", "C", subscribedAt: new DateTimeOffset(2026, 2, 1, 0, 0, 0, TimeSpan.Zero)),
        };

        Assert.Equal(["new", "mid", "old"], SubscriptionSorting.Sort(subs, SubscriptionSortOrder.RecentlyAdded).Select(s => s.Id));
    }

    [Fact]
    public void LatestEpisode_OrdersNewestFirstAndSortsUnknownDatesLast()
    {
        var subs = new[]
        {
            Sub("stale", "A", latestEpisodePublishedAt: new DateTimeOffset(2026, 1, 1, 0, 0, 0, TimeSpan.Zero)),
            Sub("fresh", "B", latestEpisodePublishedAt: new DateTimeOffset(2026, 5, 1, 0, 0, 0, TimeSpan.Zero)),
            Sub("unknown", "C", latestEpisodePublishedAt: null),
        };

        Assert.Equal(["fresh", "stale", "unknown"], SubscriptionSorting.Sort(subs, SubscriptionSortOrder.LatestEpisode).Select(s => s.Id));
    }

    [Fact]
    public void LatestEpisode_TieBreaksOnTitle()
    {
        var sameDate = new DateTimeOffset(2026, 4, 1, 0, 0, 0, TimeSpan.Zero);
        var subs = new[] { Sub("1", "zebra", latestEpisodePublishedAt: sameDate), Sub("2", "apple", latestEpisodePublishedAt: sameDate) };

        Assert.Equal(["2", "1"], SubscriptionSorting.Sort(subs, SubscriptionSortOrder.LatestEpisode).Select(s => s.Id));
    }
}
