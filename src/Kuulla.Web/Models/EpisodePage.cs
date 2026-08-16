namespace Kuulla.Web.Models;

public record EpisodePage(IReadOnlyList<Episode> Items, string? ContinuationToken);
