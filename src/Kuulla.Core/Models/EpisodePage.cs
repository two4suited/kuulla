namespace Kuulla.Core.Models;

public record EpisodePage(IReadOnlyList<Episode> Items, string? ContinuationToken);
