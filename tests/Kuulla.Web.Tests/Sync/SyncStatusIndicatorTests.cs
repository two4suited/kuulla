using Bunit;
using Kuulla.Web.Components.Sync;
using Kuulla.Web.Services.Sync;
using Moq;

namespace Kuulla.Web.Tests.Sync;

public class SyncStatusIndicatorTests : TestContext
{
    public SyncStatusIndicatorTests()
    {
        // The focus-poll JS module (wwwroot/js/syncFocusWatcher.js) isn't loadable under bunit's
        // jsdom-less runtime; Loose mode auto-mocks the dynamic import/register calls so the
        // component's own IsSyncing/HasRemoteUpdate rendering can still be exercised directly.
        JSInterop.Mode = JSRuntimeMode.Loose;
    }

    private static Mock<ISyncStatusService> MakeService(bool isSyncing = false, bool hasRemoteUpdate = false)
    {
        var service = new Mock<ISyncStatusService>();
        service.SetupGet(s => s.IsSyncing).Returns(isSyncing);
        service.SetupGet(s => s.HasRemoteUpdate).Returns(hasRemoteUpdate);
        return service;
    }

    [Fact]
    public void RendersNothing_WhenIdleAndNoRemoteUpdate()
    {
        var service = MakeService();

        var cut = RenderComponent<SyncStatusIndicator>(p => p.Add(c => c.Service, service.Object));

        Assert.DoesNotContain("Syncing", cut.Markup);
        Assert.DoesNotContain("Updated from another device", cut.Markup);
    }

    [Fact]
    public void ShowsSyncingIndicator_WhileSyncing()
    {
        var service = MakeService(isSyncing: true);

        var cut = RenderComponent<SyncStatusIndicator>(p => p.Add(c => c.Service, service.Object));

        Assert.Contains("Syncing", cut.Markup);
    }

    [Fact]
    public void ShowsUpdatedIndicator_WhenRemoteUpdateDetected()
    {
        var service = MakeService(hasRemoteUpdate: true);

        var cut = RenderComponent<SyncStatusIndicator>(p => p.Add(c => c.Service, service.Object));

        Assert.Contains("Updated from another device", cut.Markup);
    }

    [Fact]
    public void ClickingUpdatedIndicator_AcknowledgesRemoteUpdate()
    {
        var service = MakeService(hasRemoteUpdate: true);
        service.Setup(s => s.AcknowledgeRemoteUpdateAsync(It.IsAny<CancellationToken>())).Returns(Task.CompletedTask);

        var cut = RenderComponent<SyncStatusIndicator>(p => p.Add(c => c.Service, service.Object));
        cut.Find("button").Click();

        service.Verify(s => s.AcknowledgeRemoteUpdateAsync(It.IsAny<CancellationToken>()), Times.Once);
    }

    [Fact]
    public void RerendersWhenServiceRaisesStateChanged()
    {
        var service = MakeService();
        var cut = RenderComponent<SyncStatusIndicator>(p => p.Add(c => c.Service, service.Object));
        Assert.DoesNotContain("Syncing", cut.Markup);

        service.SetupGet(s => s.IsSyncing).Returns(true);
        cut.InvokeAsync(() => service.Raise(s => s.StateChanged += null));

        cut.WaitForAssertion(() => Assert.Contains("Syncing", cut.Markup));
    }
}
