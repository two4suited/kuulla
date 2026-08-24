namespace Kuulla.Api.Models;

public record SyncSettingsResult(
    IReadOnlyList<UserSettings> ServerChanges,
    DateTimeOffset SyncedAt,
    string Hash);
