using Kuulla.Web.Models;
using Kuulla.Web.Services;

namespace Kuulla.Web.Tests.Services;

public class CrossDeviceResumeTests
{
    private static readonly DateTimeOffset Now = new(2026, 8, 27, 12, 0, 0, TimeSpan.Zero);

    private static EpisodeState State(
        int positionSeconds = 600, bool completed = false, DateTimeOffset? updatedAt = null, string? deviceId = "device-x") =>
        new("ep-1", "user-1", "ep-1", "show-1", positionSeconds, completed, updatedAt ?? Now, deviceId);

    [Fact]
    public void Evaluate_ReturnsNull_WhenNoState()
    {
        Assert.Null(CrossDeviceResume.Evaluate(null, 120, Now.AddHours(-1)));
    }

    [Fact]
    public void Evaluate_ReturnsNull_WhenCompleted()
    {
        Assert.Null(CrossDeviceResume.Evaluate(State(completed: true), 0, null));
    }

    [Fact]
    public void Evaluate_Prompts_WhenNeverPlayedHereAndStateHasPosition()
    {
        var prompt = CrossDeviceResume.Evaluate(State(positionSeconds: 300), localPositionSeconds: null, localUpdatedAt: null);
        Assert.Equal(new CrossDeviceResume.Prompt(300, 0), prompt);
    }

    [Fact]
    public void Evaluate_ReturnsNull_WhenNeverPlayedHereButStatePositionIsTiny()
    {
        Assert.Null(CrossDeviceResume.Evaluate(State(positionSeconds: 5), null, null));
    }

    [Fact]
    public void Evaluate_Prompts_WhenStateMovedOnSinceThisBrowsersLastWrite()
    {
        var prompt = CrossDeviceResume.Evaluate(
            State(positionSeconds: 600, updatedAt: Now),
            localPositionSeconds: 120,
            localUpdatedAt: Now.AddMinutes(-30));
        Assert.Equal(new CrossDeviceResume.Prompt(600, 120), prompt);
    }

    [Fact]
    public void Evaluate_ReturnsNull_WhenThisBrowserIsInSyncWithTheStoredState()
    {
        Assert.Null(CrossDeviceResume.Evaluate(
            State(positionSeconds: 600, updatedAt: Now),
            localPositionSeconds: 600,
            localUpdatedAt: Now));
    }

    [Fact]
    public void Evaluate_ReturnsNull_WhenPositionsAreWithinThreshold()
    {
        Assert.Null(CrossDeviceResume.Evaluate(
            State(positionSeconds: 610, updatedAt: Now),
            localPositionSeconds: 600,
            localUpdatedAt: Now.AddMinutes(-30)));
    }

    [Fact]
    public void Evaluate_Prompts_WhenAnotherDeviceRewoundWellBehindThisBrowser()
    {
        var prompt = CrossDeviceResume.Evaluate(
            State(positionSeconds: 60, updatedAt: Now),
            localPositionSeconds: 600,
            localUpdatedAt: Now.AddMinutes(-30));
        Assert.Equal(new CrossDeviceResume.Prompt(60, 600), prompt);
    }
}
