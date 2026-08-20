namespace Kuulla.Api.Models;

// DynamicConfig is required (and validated) only when Type == Dynamic; ignored for Manual, which
// remains the default so existing manual-playlist clients don't need to send Type at all.
public record CreatePlaylistRequest(string Name, PlaylistType Type = PlaylistType.Manual, DynamicPlaylistConfig? DynamicConfig = null);
