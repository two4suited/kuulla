namespace Kuulla.Api.Models;

public record EpisodePage(IReadOnlyList<Episode> Items, string? ContinuationToken);
