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
    public void Manual_WithNoSavedOrder_FallsBackToTitle()
    {
        var subs = new[] { Sub("1", "zebra"), Sub("2", "Apple") };

        Assert.Equal(["2", "1"], SubscriptionSorting.Sort(subs, SubscriptionSortOrder.Manual).Select(s => s.Id));
    }

    [Fact]
    public void Manual_OrdersBySavedArrangement()
    {
        var subs = new[] { Sub("a", "Apple"), Sub("b", "Banana"), Sub("c", "Cherry") };

        var sorted = SubscriptionSorting.Sort(subs, SubscriptionSortOrder.Manual, ["c", "a", "b"]);

        Assert.Equal(["c", "a", "b"], sorted.Select(s => s.Id));
    }

    [Fact]
    public void Manual_ShowsNotInSavedOrderFallToEndByTitle()
    {
        var subs = new[] { Sub("a", "zeta"), Sub("b", "alpha"), Sub("c", "Cherry") };

        // Only "c" is arranged; "a"/"b" are newly subscribed and sort by title after it.
        var sorted = SubscriptionSorting.Sort(subs, SubscriptionSortOrder.Manual, ["c"]);

        Assert.Equal(["c", "b", "a"], sorted.Select(s => s.Id));
    }

    [Fact]
    public void Manual_IgnoresUnsubscribedIdsInSavedOrder()
    {
        var subs = new[] { Sub("a", "Apple"), Sub("b", "Banana") };

        var sorted = SubscriptionSorting.Sort(subs, SubscriptionSortOrder.Manual, ["ghost", "b", "a"]);

        Assert.Equal(["b", "a"], sorted.Select(s => s.Id));
    }

    [Fact]
    public void ApplyManualMove_MovesTheItemAndReturnsFullOrder()
    {
        var view = new[] { Sub("a", "A"), Sub("b", "B"), Sub("c", "C") };

        var result = SubscriptionSorting.ApplyManualMove(view, fromIndex: 2, toIndex: 0);

        Assert.Equal(["c", "a", "b"], result);
    }

    [Theory]
    [InlineData(1, 1)]   // same position
    [InlineData(-1, 0)]  // from out of range
    [InlineData(0, 5)]   // to out of range
    public void ApplyManualMove_ReturnsNullForNoOpOrOutOfRange(int from, int to)
    {
        var view = new[] { Sub("a", "A"), Sub("b", "B") };

        Assert.Null(SubscriptionSorting.ApplyManualMove(view, from, to));
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

    [Fact]
    public void LatestEpisode_SinksCaughtUpShowsBelowActiveOnesRegardlessOfDate()
    {
        var subs = new[]
        {
            Sub("caught-up-fresh", "A", latestEpisodePublishedAt: new DateTimeOffset(2026, 6, 1, 0, 0, 0, TimeSpan.Zero)),
            Sub("active-stale", "B", latestEpisodePublishedAt: new DateTimeOffset(2026, 1, 1, 0, 0, 0, TimeSpan.Zero)),
        };
        var active = new HashSet<string> { "active-stale" };

        var sorted = SubscriptionSorting.Sort(subs, SubscriptionSortOrder.LatestEpisode, activeShowIds: active);

        // "active-stale" has an older episode but still comes first — the caught-up show sinks.
        Assert.Equal(["active-stale", "caught-up-fresh"], sorted.Select(s => s.Id));
    }

    [Fact]
    public void LatestEpisode_NullActiveShowIds_LeavesOrderUnchanged()
    {
        var subs = new[]
        {
            Sub("stale", "A", latestEpisodePublishedAt: new DateTimeOffset(2026, 1, 1, 0, 0, 0, TimeSpan.Zero)),
            Sub("fresh", "B", latestEpisodePublishedAt: new DateTimeOffset(2026, 5, 1, 0, 0, 0, TimeSpan.Zero)),
        };

        Assert.Equal(["fresh", "stale"], SubscriptionSorting.Sort(subs, SubscriptionSortOrder.LatestEpisode, activeShowIds: null).Select(s => s.Id));
    }

    [Fact]
    public void HideCaughtUp_RemovesShowsNotInActiveSet()
    {
        var subs = new[] { Sub("a", "Apple"), Sub("b", "Banana"), Sub("c", "Cherry") };
        var active = new HashSet<string> { "b" };

        var sorted = SubscriptionSorting.Sort(subs, SubscriptionSortOrder.Title, activeShowIds: active, hideCaughtUp: true);

        Assert.Equal(["b"], sorted.Select(s => s.Id));
    }

    [Fact]
    public void HideCaughtUp_WithNullActiveShowIds_KeepsEveryShow()
    {
        var subs = new[] { Sub("a", "Apple"), Sub("b", "Banana") };

        var sorted = SubscriptionSorting.Sort(subs, SubscriptionSortOrder.Title, activeShowIds: null, hideCaughtUp: true);

        Assert.Equal(["a", "b"], sorted.Select(s => s.Id));
    }

    [Fact]
    public void HideCaughtUp_IgnoredInManualMode()
    {
        var subs = new[] { Sub("a", "Apple"), Sub("b", "Banana"), Sub("c", "Cherry") };
        var active = new HashSet<string> { "b" };

        var sorted = SubscriptionSorting.Sort(
            subs, SubscriptionSortOrder.Manual, ["c", "a", "b"], activeShowIds: active, hideCaughtUp: true);

        // Manual is a hand-curated arrangement — every subscribed show still shows.
        Assert.Equal(["c", "a", "b"], sorted.Select(s => s.Id));
    }
}
