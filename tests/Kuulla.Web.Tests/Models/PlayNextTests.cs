using Kuulla.Web.Models;

namespace Kuulla.Web.Tests.Models;

// The pure "what plays next" decisions behind EpisodeDetail.razor's auto-advance (#629). These
// must agree with PlaybackQueueTests on iOS — the same list can be finished on either client.
public class PlayNextTests
{
    private static IReadOnlyList<PlaybackListItem> Items(params string[] episodeIds) =>
        episodeIds.Select(id => new PlaybackListItem($"show-{id}", id)).ToList();

    [Fact]
    public void NextInList_ReturnsTheFollowingItem()
    {
        var next = PlayNext.NextItem("b", Items("a", "b", "c"), PlayNextBehavior.NextInList);

        Assert.Equal(new PlaybackListItem("show-c", "c"), next);
    }

    [Fact]
    public void NextInList_IsNullAtTheEndOfTheList()
    {
        Assert.Null(PlayNext.NextItem("c", Items("a", "b", "c"), PlayNextBehavior.NextInList));
    }

    [Fact]
    public void NextInList_IsNullWhenTheFinishedEpisodeIsNotInTheList()
    {
        // A reorder/removal race: stop rather than guess.
        Assert.Null(PlayNext.NextItem("gone", Items("a", "b", "c"), PlayNextBehavior.NextInList));
    }

    [Fact]
    public void TopOfList_ReturnsTheFirstItemThatIsNotTheFinishedOne()
    {
        var next = PlayNext.NextItem("a", Items("a", "b", "c"), PlayNextBehavior.TopOfList);

        Assert.Equal(new PlaybackListItem("show-b", "b"), next);
    }

    [Fact]
    public void TopOfList_ReturnsTheFirstItemWhenTheFinishedOneIsElsewhere()
    {
        var next = PlayNext.NextItem("c", Items("a", "b", "c"), PlayNextBehavior.TopOfList);

        Assert.Equal(new PlaybackListItem("show-a", "a"), next);
    }

    [Fact]
    public void TopOfList_IsNullWhenOnlyTheFinishedEpisodeRemains()
    {
        Assert.Null(PlayNext.NextItem("only", Items("only"), PlayNextBehavior.TopOfList));
    }

    [Fact]
    public void Stop_IsAlwaysNull()
    {
        Assert.Null(PlayNext.NextItem("a", Items("a", "b", "c"), PlayNextBehavior.Stop));
    }

    [Fact]
    public void Resolve_PrefersPlaylistThenShowThenGlobal()
    {
        Assert.Equal(PlayNextBehavior.Stop, PlayNext.Resolve(PlayNextBehavior.Stop, PlayNextBehavior.TopOfList, PlayNextBehavior.NextInList));
        Assert.Equal(PlayNextBehavior.TopOfList, PlayNext.Resolve(null, PlayNextBehavior.TopOfList, PlayNextBehavior.NextInList));
        Assert.Equal(PlayNextBehavior.NextInList, PlayNext.Resolve(null, null, PlayNextBehavior.NextInList));
    }

    [Fact]
    public void PlaybackListQuery_BuildsTheQueryStringsEpisodeDetailParses()
    {
        Assert.Equal("?list=show&filter=Unplayed&sort=OldestFirst", PlaybackListQuery.ForShow(EpisodeFilter.Unplayed, EpisodeSortOrder.OldestFirst));
        Assert.Equal("?list=playlist&listId=up%20next", PlaybackListQuery.ForPlaylist("up next"));
        Assert.Equal("?list=new", PlaybackListQuery.ForNewEpisodes());
    }
}

public class EpisodeListOrderingTests
{
    private static Episode Ep(string id, int daysAgo) => new(
        id, "show-1", id, DateTimeOffset.UtcNow.AddDays(-daysAgo), TimeSpan.FromMinutes(20), "https://audio", null, null, null);

    private static EpisodeState State(string id, int position, bool completed, bool autoPlayed = false, bool archived = false) =>
        new(id, "user-1", id, "show-1", position, completed, DateTimeOffset.UtcNow, "web", AutoPlayed: autoPlayed, Archived: archived);

    // Newest first, as the API pages them.
    private static readonly List<Episode> Episodes = [Ep("new", 0), Ep("progress", 1), Ep("played", 2), Ep("auto", 3), Ep("archived", 4)];

    private static readonly Dictionary<string, EpisodeState> States = new()
    {
        ["progress"] = State("progress", 300, completed: false),
        ["played"] = State("played", 1200, completed: true),
        ["auto"] = State("auto", 1200, completed: true, autoPlayed: true),
        ["archived"] = State("archived", 1200, completed: true, archived: true),
    };

    [Fact]
    public void All_ExcludesOnlyArchivedEpisodes()
    {
        var result = EpisodeListOrdering.Apply(Episodes, States, EpisodeFilter.All, EpisodeSortOrder.NewestFirst);

        Assert.Equal(["new", "progress", "played", "auto"], result.Select(e => e.Id));
    }

    [Fact]
    public void Unfinished_KeepsUnplayedAndInProgress()
    {
        var result = EpisodeListOrdering.Apply(Episodes, States, EpisodeFilter.Unfinished, EpisodeSortOrder.NewestFirst);

        Assert.Equal(["new", "progress"], result.Select(e => e.Id));
    }

    [Fact]
    public void Unplayed_TreatsAutoPlayedAsPlayed()
    {
        var result = EpisodeListOrdering.Apply(Episodes, States, EpisodeFilter.Unplayed, EpisodeSortOrder.NewestFirst);

        Assert.Equal(["new"], result.Select(e => e.Id));
    }

    [Fact]
    public void InProgress_KeepsOnlyPartiallyPlayed()
    {
        var result = EpisodeListOrdering.Apply(Episodes, States, EpisodeFilter.InProgress, EpisodeSortOrder.NewestFirst);

        Assert.Equal(["progress"], result.Select(e => e.Id));
    }

    [Fact]
    public void OldestFirst_ReversesTheApiOrder()
    {
        var result = EpisodeListOrdering.Apply(Episodes, States, EpisodeFilter.Unfinished, EpisodeSortOrder.OldestFirst);

        Assert.Equal(["progress", "new"], result.Select(e => e.Id));
    }
}
