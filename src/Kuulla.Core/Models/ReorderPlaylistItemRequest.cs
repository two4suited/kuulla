namespace Kuulla.Core.Models;

// Exactly one of BeforeEpisodeId/AfterEpisodeId may be omitted (moving to an end of the list),
// but not both — the service computes the new item's midpoint rank between whichever neighbors
// are given rather than trusting a client-supplied rank (see PlaylistRankGenerator).
public record ReorderPlaylistItemRequest(string? BeforeEpisodeId, string? AfterEpisodeId);
