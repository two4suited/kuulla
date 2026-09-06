using Kuulla.Api.Services;
using Kuulla.Core.Services;

namespace Kuulla.Api.Tests;

public class PlaylistRankGeneratorTests
{
    [Fact]
    public void Between_NoBounds_ReturnsNonEmptyRank()
    {
        var rank = PlaylistRankGenerator.Between(null, null);

        Assert.False(string.IsNullOrEmpty(rank));
    }

    [Fact]
    public void Between_NoLowerBound_SortsBeforeUpperBound()
    {
        var rank = PlaylistRankGenerator.Between(null, "5");

        Assert.True(string.CompareOrdinal(rank, "5") < 0);
    }

    [Fact]
    public void Between_NoUpperBound_SortsAfterLowerBound()
    {
        var rank = PlaylistRankGenerator.Between("5", null);

        Assert.True(string.CompareOrdinal("5", rank) < 0);
    }

    [Fact]
    public void Between_BothBounds_SortsStrictlyBetweenThem()
    {
        var rank = PlaylistRankGenerator.Between("5", "6");

        Assert.True(string.CompareOrdinal("5", rank) < 0);
        Assert.True(string.CompareOrdinal(rank, "6") < 0);
    }

    [Fact]
    public void Between_AdjacentBounds_StillFindsARankByGrowingPrecision()
    {
        // "5" and "6" are lexicographically adjacent single characters — there's no gap at
        // length 1, so this exercises the length-widening loop.
        var rank = PlaylistRankGenerator.Between("5", "6");

        Assert.NotEqual("5", rank);
        Assert.NotEqual("6", rank);
    }

    [Fact]
    public void Between_RepeatedInsertionsBetweenSameNeighbors_StaySortedAndDistinct()
    {
        var low = "5";
        var high = "6";
        var ranks = new List<string>();

        var current = high;
        for (var i = 0; i < 20; i++)
        {
            current = PlaylistRankGenerator.Between(low, current);
            ranks.Add(current);
        }

        // Each successive insertion is squeezed directly below the previous one, so the
        // resulting sequence should already be in descending order and, combined with `low`
        // and `high`, form a strictly increasing chain when reversed.
        var chain = new List<string> { low };
        chain.AddRange(Enumerable.Reverse(ranks));
        chain.Add(high);

        for (var i = 1; i < chain.Count; i++)
        {
            Assert.True(
                string.CompareOrdinal(chain[i - 1], chain[i]) < 0,
                $"Expected '{chain[i - 1]}' < '{chain[i]}'");
        }
    }

    [Fact]
    public void Between_InvalidBounds_Throws()
    {
        Assert.Throws<ArgumentException>(() => PlaylistRankGenerator.Between("6", "5"));
        Assert.Throws<ArgumentException>(() => PlaylistRankGenerator.Between("5", "5"));
    }

    [Fact]
    public void Between_AppendingRepeatedlyAtTheEnd_StaysSorted()
    {
        var ranks = new List<string>();
        string? previous = null;

        for (var i = 0; i < 20; i++)
        {
            previous = PlaylistRankGenerator.Between(previous, null);
            ranks.Add(previous);
        }

        for (var i = 1; i < ranks.Count; i++)
        {
            Assert.True(string.CompareOrdinal(ranks[i - 1], ranks[i]) < 0);
        }
    }
}
