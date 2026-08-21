using System.Net;
using System.Net.Http.Json;
using Kuulla.Web.Components.Pages;
using Kuulla.Web.Models;

namespace Kuulla.Web.Tests.Pages;

public class SettingsTests : WebTestContext
{
    private static readonly UserSettings DefaultSettings = new("user-1", UnlistenedEpisodeCount.Five, Version: 1, AutoArchiveRule.Never);

    private static TestHttpMessageHandler CreateHandler(
        UserSettings? getResponse = null, UserSettings? putResponse = null, UserSettings? archivePutResponse = null) =>
        new(request =>
        {
            if (request.RequestUri!.AbsolutePath == "/api/settings" && request.Method == HttpMethod.Get)
            {
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = JsonContent.Create(getResponse ?? DefaultSettings),
                };
            }

            if (request.RequestUri!.AbsolutePath == "/api/settings" && request.Method == HttpMethod.Put)
            {
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = JsonContent.Create(putResponse ?? DefaultSettings),
                };
            }

            if (request.RequestUri!.AbsolutePath == "/api/settings/auto-archive" && request.Method == HttpMethod.Put)
            {
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = JsonContent.Create(archivePutResponse ?? DefaultSettings),
                };
            }

            return new HttpResponseMessage(HttpStatusCode.NotFound);
        });

    public SettingsTests()
    {
        AuthContext.SetAuthorized("user-1");
    }

    [Fact]
    public void RendersCurrentSetting_WhenLoadSucceeds()
    {
        ConfigureApi(CreateHandler());

        var cut = RenderComponent<Settings>();

        cut.WaitForAssertion(() => Assert.Equal("Five", cut.Find("#unlistened-episode-count").GetAttribute("value")));
    }

    [Fact]
    public void ShowsErrorMessage_WhenLoadFails()
    {
        ConfigureApi(TestHttpMessageHandler.Status(HttpStatusCode.InternalServerError));

        var cut = RenderComponent<Settings>();

        cut.WaitForAssertion(() => Assert.Contains("Something went wrong", cut.Markup));
    }

    [Fact]
    public void SavesAndConfirms_WhenSelectionChanges()
    {
        ConfigureApi(CreateHandler(putResponse: new("user-1", UnlistenedEpisodeCount.Unlimited, Version: 2)));

        var cut = RenderComponent<Settings>();
        cut.WaitForAssertion(() => Assert.Contains("Unlistened episodes", cut.Markup));

        cut.Find("#unlistened-episode-count").Change("Unlimited");

        cut.WaitForAssertion(() => Assert.Contains("Saved.", cut.Markup));
    }

    [Fact]
    public void ShowsErrorAndReverts_WhenSaveFails()
    {
        ConfigureApi(new TestHttpMessageHandler(request =>
            request.Method == HttpMethod.Put
                ? new HttpResponseMessage(HttpStatusCode.InternalServerError)
                : new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(DefaultSettings) }));

        var cut = RenderComponent<Settings>();
        cut.WaitForAssertion(() => Assert.Equal("Five", cut.Find("#unlistened-episode-count").GetAttribute("value")));

        cut.Find("#unlistened-episode-count").Change("Unlimited");

        cut.WaitForAssertion(() =>
        {
            Assert.Contains("Something went wrong", cut.Markup);
            Assert.Equal("Five", cut.Find("#unlistened-episode-count").GetAttribute("value"));
        });
    }

    [Fact]
    public void RendersCurrentAutoArchiveRule_WhenLoadSucceeds()
    {
        ConfigureApi(CreateHandler(getResponse: new("user-1", UnlistenedEpisodeCount.Five, Version: 1, AutoArchiveRule.After7Days)));

        var cut = RenderComponent<Settings>();

        cut.WaitForAssertion(() => Assert.Equal("After7Days", cut.Find("#auto-archive-rule").GetAttribute("value")));
    }

    [Fact]
    public void SavesAndConfirmsAutoArchiveRule_WhenSelectionChanges()
    {
        ConfigureApi(CreateHandler(archivePutResponse: new("user-1", UnlistenedEpisodeCount.Five, Version: 2, AutoArchiveRule.AfterPlayed)));

        var cut = RenderComponent<Settings>();
        cut.WaitForAssertion(() => Assert.Contains("Auto-archive", cut.Markup));

        cut.Find("#auto-archive-rule").Change("AfterPlayed");

        cut.WaitForAssertion(() => Assert.Contains("Saved.", cut.Markup));
    }
}
