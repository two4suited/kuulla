using Microsoft.Playwright;
using Xunit;

namespace Kuulla.Web.E2E;

// Exercises search against the real iTunes podcast directory (ShowService.SearchAsync has no
// dev/test double — see ItunesPodcastDirectoryClient) and plays a real episode audio file end to
// end, rather than seeding through /dev/seed-show like SubscriptionTests. That trades some
// network-dependent flakiness for actually proving the browse -> show -> episode -> playback path
// works against a real feed and a real audio file, not just wiring.
[Collection(WebAppCollection.Name)]
public class BrowseAndPlaybackTests(WebAppFixture fixture)
{
    private const string SearchTerm = "Radiolab";

    [Fact]
    public async Task Search_OpenShow_OpenEpisode_AndPlayAudio()
    {
        var page = await fixture.NewPageAsync();
        try
        {
            await page.GotoAsync("/search");
            await page.GetByPlaceholder("Search for a show...").FillAsync(SearchTerm);
            await page.GetByRole(AriaRole.Button, new() { Name = "Search" }).ClickAsync();

            // ClickAsync auto-waits for the element to become actionable, so no separate
            // WaitForAsync is needed before it.
            var firstResult = page.Locator(".row.row-cols-2 a").First;
            await firstResult.ClickAsync();
            await page.WaitForURLAsync(url => url.Contains("/shows/"));

            // Longer timeout than the default 30s: the first load of a show's episode list
            // fetches and parses the real RSS feed server-side (Kuulla.Api's EpisodeService),
            // which can be slower than a typical UI action.
            var firstEpisode = page.Locator(".list-group-item a").First;
            await firstEpisode.ClickAsync(new() { Timeout = 45_000 });
            await page.WaitForURLAsync(url => url.Contains("/episodes/"));

            var audio = page.Locator("audio");
            await audio.WaitForAsync();

            var source = await audio.Locator("source").GetAttributeAsync("src");
            Assert.False(string.IsNullOrEmpty(source));

            // The native <audio controls> play button sits at the far left of the control bar,
            // and native controls are a closed shadow root Playwright can't address by
            // role/label — a real click on it (rather than calling el.play() from script) is
            // what preserves the user-gesture that Chromium's autoplay policy requires. Position
            // is relative to the element itself, so this stays centered regardless of the
            // control bar's rendered height.
            var box = await audio.BoundingBoxAsync();
            Assert.NotNull(box);
            await audio.ClickAsync(new LocatorClickOptions { Position = new Position { X = 20, Y = box!.Height / 2 } });

            await page.WaitForFunctionAsync(
                "() => { const el = document.querySelector('audio'); return el && !el.paused; }",
                new PageWaitForFunctionOptions { Timeout = 15_000 });
        }
        finally
        {
            // Closes the page's owning context too, so its cookies/storage don't linger for
            // the rest of the (shared, collection-scoped) fixture's lifetime.
            await page.Context.CloseAsync();
        }
    }
}
