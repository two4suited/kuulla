namespace Kuulla.Core.Models;

// Changes holds 0 or 1 items: unlike episodes/playlists, a user has exactly one UserSettings
// record, so there's never more than one change to push per sync call. An empty list is a poll
// (client only wants the current hash/delta, not pushing a local edit).
public record SyncSettingsRequest(
    string DeviceId,
    DateTimeOffset LastSyncedAt,
    string LocalHash,
    IReadOnlyList<UserSettingsChange> Changes);
