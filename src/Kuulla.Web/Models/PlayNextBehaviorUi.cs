namespace Kuulla.Web.Models;

// Display labels for the PlayNextBehavior picker (#629), shared by the global Settings page, the
// per-show gear popover and the playlist edit panel so all three read the same way.
public static class PlayNextBehaviorUi
{
    public static readonly IReadOnlyList<PlayNextBehavior> Options =
        [PlayNextBehavior.NextInList, PlayNextBehavior.TopOfList, PlayNextBehavior.Stop];

    public static string Format(PlayNextBehavior behavior) => behavior switch
    {
        PlayNextBehavior.NextInList => "Play the next episode in the list",
        PlayNextBehavior.TopOfList => "Play from the top of the list",
        PlayNextBehavior.Stop => "Stop",
        _ => behavior.ToString(),
    };
}
