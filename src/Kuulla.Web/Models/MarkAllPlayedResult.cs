namespace Kuulla.Web.Models;

// Web-side mirror of Kuulla.Core.Models.MarkAllPlayedResult's wire shape
// (POST /api/shows/{showId}/episode-state/mark-all-played).
public record MarkAllPlayedResult(
    int TotalEpisodes,
    int UpdatedCount,
    IReadOnlyList<EpisodeState> UpdatedStates);
