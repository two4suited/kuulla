using Bunit;
using Kuulla.Web.Components;
using Kuulla.Web.Models;
using Microsoft.JSInterop;

namespace Kuulla.Web.Tests.Components;

public class ShowIconSizeSelectTests : WebTestContext
{
    [Fact]
    public void ReadsStoredValueOnFirstRender_AndRaisesValueChanged()
    {
        JSInterop.Setup<string?>("localStorage.getItem", ShowIconSizes.StorageKey).SetResult("Small");
        ShowIconSize? changed = null;

        var cut = RenderComponent<ShowIconSizeSelect>(p => p
            .Add(c => c.Value, ShowIconSize.Large)
            .Add(c => c.ValueChanged, (ShowIconSize s) => changed = s));

        cut.WaitForAssertion(() => Assert.Equal(ShowIconSize.Small, changed));
    }

    [Fact]
    public void DoesNotRaiseValueChanged_WhenStoredValueMatchesCurrent()
    {
        JSInterop.Setup<string?>("localStorage.getItem", ShowIconSizes.StorageKey).SetResult("Large");
        var raised = false;

        var cut = RenderComponent<ShowIconSizeSelect>(p => p
            .Add(c => c.Value, ShowIconSize.Large)
            .Add(c => c.ValueChanged, (ShowIconSize _) => raised = true));

        // The control still enables itself once the first read completes.
        cut.WaitForAssertion(() => Assert.False(cut.Find("select").HasAttribute("disabled")));
        Assert.False(raised);
    }

    [Fact]
    public void FallsBackToDefault_WhenLocalStorageReadThrows()
    {
        JSInterop.Setup<string?>("localStorage.getItem", ShowIconSizes.StorageKey)
            .SetException(new JSException("blocked"));
        ShowIconSize? changed = null;

        var cut = RenderComponent<ShowIconSizeSelect>(p => p
            .Add(c => c.Value, ShowIconSize.Small)
            .Add(c => c.ValueChanged, (ShowIconSize s) => changed = s));

        // Read failed → resolves to the default (Large), which differs from the passed-in Value.
        cut.WaitForAssertion(() => Assert.Equal(ShowIconSize.Large, changed));
        Assert.False(cut.Find("select").HasAttribute("disabled"));
    }

    [Fact]
    public void WritesSelectionToLocalStorage_AndRaisesValueChanged_OnChange()
    {
        JSInterop.Mode = JSRuntimeMode.Loose;
        ShowIconSize? changed = null;

        var cut = RenderComponent<ShowIconSizeSelect>(p => p
            .Add(c => c.Value, ShowIconSize.Large)
            .Add(c => c.ValueChanged, (ShowIconSize s) => changed = s));

        cut.WaitForState(() => !cut.Find("select").HasAttribute("disabled"));
        cut.Find("select").Change("Medium");

        Assert.Equal(ShowIconSize.Medium, changed);
        var invocation = JSInterop.Invocations["localStorage.setItem"].Last();
        Assert.Equal(ShowIconSizes.StorageKey, invocation.Arguments[0]);
        Assert.Equal("Medium", invocation.Arguments[1]);
    }

    [Fact]
    public void StillRaisesValueChanged_WhenLocalStorageWriteThrows()
    {
        JSInterop.Setup<string?>("localStorage.getItem", ShowIconSizes.StorageKey).SetResult(null);
        JSInterop.SetupVoid("localStorage.setItem", ShowIconSizes.StorageKey, "Small")
            .SetException(new JSException("blocked"));
        ShowIconSize? changed = null;

        var cut = RenderComponent<ShowIconSizeSelect>(p => p
            .Add(c => c.Value, ShowIconSize.Large)
            .Add(c => c.ValueChanged, (ShowIconSize s) => changed = s));

        cut.WaitForState(() => !cut.Find("select").HasAttribute("disabled"));
        cut.Find("select").Change("Small");

        Assert.Equal(ShowIconSize.Small, changed);
    }
}
