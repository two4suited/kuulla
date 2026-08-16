namespace Kuulla.Web;

public static class EpisodeFormatting
{
    public static string FormatDuration(TimeSpan duration) =>
        duration.TotalHours >= 1
            ? duration.ToString(@"h\:mm\:ss")
            : duration.ToString(@"m\:ss");
}
