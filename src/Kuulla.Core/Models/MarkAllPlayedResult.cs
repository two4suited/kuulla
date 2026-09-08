namespace Kuulla.Core.Models;

// Response for POST /api/shows/{showId}/episode-state/mark-all-played.
// - TotalEpisodes: how many episodes are known for the show (the mark's candidate set).
// - UpdatedStates: the episode-state rows actually written this call — episodes the user had
//   already marked played are left untouched so a re-run is a no-op (idempotent), so on a
//   second call this is empty. Clients merge these into their local view and/or refetch.
public record MarkAllPlayedResult(
    int TotalEpisodes,
    int UpdatedCount,
    IReadOnlyList<EpisodeState> UpdatedStates);
