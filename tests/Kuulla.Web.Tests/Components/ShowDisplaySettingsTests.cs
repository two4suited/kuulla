using Bunit;
using Kuulla.Web.Components;
using Kuulla.Web.Models;
using Microsoft.JSInterop;

namespace Kuulla.Web.Tests.Components;

public class ShowDisplaySettingsTests : WebTestContext
{
    private IRenderedComponent<ShowDisplaySettings> Render(
        SubscriptionSortOrder sortOrder = SubscriptionSortOrder.Title,
        bool hideCaughtUpShows = false,
        ShowIconSize iconSize = ShowIconSize.Large,
        Action<SubscriptionSortOrder>? onSortOrderChanged = null,
        Action<bool>? onHideCaughtUpShowsChanged = null,
        Action<ShowIconSize>? onIconSizeChanged = null)
        => RenderComponent<ShowDisplaySettings>(p =>
        {
            p.Add(c => c.SortOrder, sortOrder);
            p.Add(c => c.HideCaughtUpShows, hideCaughtUpShows);
            p.Add(c => c.IconSize, iconSize);
            if (onSortOrderChanged is not null)
            {
                p.Add(c => c.SortOrderChanged, onSortOrderChanged);
            }

            if (onHideCaughtUpShowsChanged is not null)
            {
                p.Add(c => c.HideCaughtUpShowsChanged, onHideCaughtUpShowsChanged);
            }

            if (onIconSizeChanged is not null)
            {
                p.Add(c => c.IconSizeChanged, onIconSizeChanged);
            }
        });

    private static void OpenPopover(IRenderedComponent<ShowDisplaySettings> cut)
        => cut.Find("button[aria-label='Display settings']").Click();

    [Fact]
    public void ReadsStoredIconSize_OnFirstRender_AndRaisesIconSizeChanged()
    {
        JSInterop.Setup<string?>("localStorage.getItem", ShowIconSizes.StorageKey).SetResult("Small");
        ShowIconSize? changed = null;

        var cut = Render(iconSize: ShowIconSize.Large, onIconSizeChanged: s => changed = s);

        // First render reads the stored value even without the popover being opened.
        cut.WaitForAssertion(() => Assert.Equal(ShowIconSize.Small, changed));
    }

    [Fact]
    public void DoesNotRaiseIconSizeChanged_WhenStoredValueMatchesCurrent()
    {
        JSInterop.Setup<string?>("localStorage.getItem", ShowIconSizes.StorageKey).SetResult("Large");
        var raised = false;

        var cut = Render(iconSize: ShowIconSize.Large, onIconSizeChanged: _ => raised = true);

        OpenPopover(cut);
        cut.WaitForAssertion(() =>
            Assert.All(cut.FindAll(".icon-size-group button"), b => Assert.False(b.HasAttribute("disabled"))));
        Assert.False(raised);
    }

    [Fact]
    public void FallsBackToDefault_WhenLocalStorageReadThrows()
    {
        JSInterop.Setup<string?>("localStorage.getItem", ShowIconSizes.StorageKey)
            .SetException(new JSException("blocked"));
        ShowIconSize? changed = null;

        var cut = Render(iconSize: ShowIconSize.Small, onIconSizeChanged: s => changed = s);

        // Read failed → resolves to the default (Large), which differs from the passed-in value.
        cut.WaitForAssertion(() => Assert.Equal(ShowIconSize.Large, changed));
    }

    [Fact]
    public void WritesIconSizeToLocalStorage_AndRaisesIconSizeChanged_OnClick()
    {
        JSInterop.Mode = JSRuntimeMode.Loose;
        ShowIconSize? changed = null;

        var cut = Render(iconSize: ShowIconSize.Large, onIconSizeChanged: s => changed = s);

        OpenPopover(cut);
        cut.WaitForState(() => !cut.FindAll(".icon-size-group button").First().HasAttribute("disabled"));
        cut.FindAll(".icon-size-group button").Single(b => b.TextContent.Trim() == "Medium").Click();

        Assert.Equal(ShowIconSize.Medium, changed);
        var invocation = JSInterop.Invocations["localStorage.setItem"].Last();
        Assert.Equal(ShowIconSizes.StorageKey, invocation.Arguments[0]);
        Assert.Equal("Medium", invocation.Arguments[1]);
    }

    [Fact]
    public void StillRaisesIconSizeChanged_WhenLocalStorageWriteThrows()
    {
        JSInterop.Setup<string?>("localStorage.getItem", ShowIconSizes.StorageKey).SetResult(null);
        JSInterop.SetupVoid("localStorage.setItem", ShowIconSizes.StorageKey, "Small")
            .SetException(new JSException("blocked"));
        ShowIconSize? changed = null;

        var cut = Render(iconSize: ShowIconSize.Large, onIconSizeChanged: s => changed = s);

        OpenPopover(cut);
        cut.WaitForState(() => !cut.FindAll(".icon-size-group button").First().HasAttribute("disabled"));
        cut.FindAll(".icon-size-group button").Single(b => b.TextContent.Trim() == "Small").Click();

        Assert.Equal(ShowIconSize.Small, changed);
    }

    [Fact]
    public void RaisesSortOrderChanged_WhenSortOptionClicked()
    {
        JSInterop.Mode = JSRuntimeMode.Loose;
        SubscriptionSortOrder? changed = null;

        var cut = Render(sortOrder: SubscriptionSortOrder.Title, onSortOrderChanged: s => changed = s);

        OpenPopover(cut);
        cut.FindAll(".sort-option").Single(b => b.TextContent.Contains("Latest episode")).Click();

        Assert.Equal(SubscriptionSortOrder.LatestEpisode, changed);
    }

    [Fact]
    public void RaisesHideCaughtUpShowsChanged_WhenToggled()
    {
        JSInterop.Mode = JSRuntimeMode.Loose;
        bool? changed = null;

        var cut = Render(hideCaughtUpShows: false, onHideCaughtUpShowsChanged: v => changed = v);

        OpenPopover(cut);
        cut.Find("input[type=checkbox]").Change(true);

        Assert.True(changed);
    }

    [Fact]
    public void TogglesPopover_OnGearClick()
    {
        JSInterop.Mode = JSRuntimeMode.Loose;
        var cut = Render();

        Assert.Empty(cut.FindAll(".show-display-settings-panel"));
        OpenPopover(cut);
        Assert.Single(cut.FindAll(".show-display-settings-panel"));
        OpenPopover(cut);
        Assert.Empty(cut.FindAll(".show-display-settings-panel"));
    }
}
