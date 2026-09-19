namespace Kuulla.Core.Models;

// PUT /api/playlists/{id} is the "edit playlist" request — it sets Name, Icon, AccentColor,
// PlayNextBehavior, and AutoDownload to the supplied values (a null Icon/AccentColor clears it; a null
// PlayNextBehavior clears the per-playlist override back to "inherit", #629). Callers send the
// playlist's full desired state, not a partial patch, so the edit UI must round-trip the current
// icon / override when the user only changes the name. AutoDownload is nullable solely for
// compatibility with clients released before the setting existed; omission preserves its value.
public record RenamePlaylistRequest(
    string Name, string? Icon = null, string? AccentColor = null, PlayNextBehavior? PlayNextBehavior = null,
    bool? AutoDownload = null);
