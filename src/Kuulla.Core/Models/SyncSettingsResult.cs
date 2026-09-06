namespace Kuulla.Core.Models;

public record SyncSettingsResult(
    IReadOnlyList<UserSettings> ServerChanges,
    DateTimeOffset SyncedAt,
    string Hash);
