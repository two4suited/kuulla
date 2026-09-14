namespace Kuulla.Web.Models;

// Formats PlaylistDetail.razor's RemainingQueueDuration (#724) — already speed-adjusted, so this
// is pure display formatting, not a duration calculation. Coarser than EpisodeFormatting's
// clock-style h:mm:ss (fine for a single episode's length) since a queue total is routinely
// several hours and "3:24:10 left" reads as a timestamp, not an estimate.
public static class QueueTimeEstimate
{
    public static string Format(TimeSpan duration)
    {
        var totalMinutes = (int)Math.Round(duration.TotalMinutes);
        if (totalMinutes < 1)
        {
            return "<1m";
        }

        var hours = totalMinutes / 60;
        var minutes = totalMinutes % 60;
        return hours > 0 ? $"{hours}h {minutes}m" : $"{minutes}m";
    }
}
