namespace Kuulla.Api.Models;

// PUT /api/playlists/{id} is the "edit playlist" request — it sets Name, Icon and AccentColor to
// the supplied values (a null Icon/AccentColor clears it). Callers send the playlist's full
// desired display state, not a partial patch, so the edit UI must round-trip the current icon
// when the user only changes the name.
public record RenamePlaylistRequest(string Name, string? Icon = null, string? AccentColor = null);
