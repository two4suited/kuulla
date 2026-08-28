using Kuulla.Web.Models;

namespace Kuulla.Web.Services;

// Decides whether opening an episode should offer "continue from where you left off on another
// device" (#243) — the Web mirror of iOS's CrossDeviceResume. Pure so the branch logic is
// unit-testable without a rendered component or a browser.
public static class CrossDeviceResume
{
    // Minimum gap between the synced position and this browser's own last position before the
    // prompt is worth showing — below this they're effectively in the same spot.
    public const int MinimumDeltaSeconds = 15;

    // OtherDevicePositionSeconds is what "Resume" jumps to; LocalPositionSeconds is what "Not
    // now" keeps (0 when this browser has never played the episode).
    public record Prompt(int OtherDevicePositionSeconds, int LocalPositionSeconds);

    // localPositionSeconds / localUpdatedAt come from this browser's localStorage record of the
    // last position it played for this episode (and the server UpdatedAt it was in sync with),
    // or null when it has never played the episode here.
    public static Prompt? Evaluate(EpisodeState? state, int? localPositionSeconds, DateTimeOffset? localUpdatedAt)
    {
        // A finished episode has nothing to resume; opening it is a deliberate replay.
        if (state is null || state.Completed)
        {
            return null;
        }

        // Never played here: any stored position must have been set from somewhere else.
        if (localUpdatedAt is null)
        {
            return Math.Abs(state.PositionSeconds) >= MinimumDeltaSeconds
                ? new Prompt(state.PositionSeconds, 0)
                : null;
        }

        // The stored state has to have moved on since this browser last wrote it — otherwise this
        // browser's own position is the most recent truth and there's nothing to hand off.
        if (state.UpdatedAt <= localUpdatedAt.Value)
        {
            return null;
        }

        var local = localPositionSeconds ?? 0;
        return Math.Abs(state.PositionSeconds - local) >= MinimumDeltaSeconds
            ? new Prompt(state.PositionSeconds, local)
            : null;
    }
}

// Decides whether an in-progress playback session should surface the "now playing on another
// device" banner (#244) — the Web mirror of iOS's CrossDeviceHandoff. Never seeks on its own.
public static class CrossDeviceHandoff
{
    public const int MinimumDeltaSeconds = CrossDeviceResume.MinimumDeltaSeconds;

    // TargetPositionSeconds is where tapping the banner seeks to; SourceUpdatedAt is the stored
    // state's UpdatedAt that produced it, so the same remote write isn't surfaced twice.
    public record Banner(int TargetPositionSeconds, DateTimeOffset SourceUpdatedAt);

    public static Banner? Evaluate(
        EpisodeState? state, int currentPlaybackPositionSeconds, DateTimeOffset? lastSurfacedUpdatedAt)
    {
        if (state is null || state.Completed)
        {
            return null;
        }

        // Only when the last write came from something other than a web client — our own
        // position pushes all report DeviceId == "web".
        if (state.DeviceId is null || state.DeviceId == EpisodeStateClient.WebDeviceId)
        {
            return null;
        }

        // Already surfaced (or dismissed) a banner for this remote write.
        if (lastSurfacedUpdatedAt is not null && state.UpdatedAt <= lastSurfacedUpdatedAt.Value)
        {
            return null;
        }

        return Math.Abs(state.PositionSeconds - currentPlaybackPositionSeconds) >= MinimumDeltaSeconds
            ? new Banner(state.PositionSeconds, state.UpdatedAt)
            : null;
    }
}
