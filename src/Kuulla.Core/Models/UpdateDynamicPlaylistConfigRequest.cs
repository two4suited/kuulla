namespace Kuulla.Core.Models;

// PUT /api/playlists/{id}/config's request body.
public record UpdateDynamicPlaylistConfigRequest(
    IReadOnlyList<string> ShowIds, int? MaxEpisodes, IReadOnlyList<string> PriorityList);
