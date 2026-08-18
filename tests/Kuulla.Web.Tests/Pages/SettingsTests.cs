using System.Net;
using System.Net.Http.Json;
using Kuulla.Web.Components.Pages;
using Kuulla.Web.Models;

namespace Kuulla.Web.Tests.Pages;

public class SettingsTests : WebTestContext
{
    private static readonly UserSettings DefaultSettings = new("user-1", UnlistenedEpisodeCount.Five, Version: 1);

    private static TestHttpMessageHandler CreateHandler(UserSettings? getResponse = null, UserSettings? putResponse = null) =>
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
}
