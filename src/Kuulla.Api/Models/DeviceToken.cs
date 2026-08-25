using Newtonsoft.Json;

namespace Kuulla.Api.Models;

// A registered Apple Push Notification token for one device belonging to one user. Not a
// synced/user-facing settings document (unlike UserSettings/ShowSettings) — purely internal
// bookkeeping so the notification-send path can look up which devices to push to. Stored in its
// own "devicetokens" container, partitioned by UserId: sending a push to "all of a user's
// devices" is then a single-partition query instead of a cross-partition fan-out.
// A user can have multiple device tokens (e.g. two iPhones), each its own document — the
// composite id (UserId + DeviceId) makes re-registering the same device on relaunch an idempotent
// upsert rather than accumulating duplicate rows.
public record DeviceToken(
    [property: JsonProperty("id")] string Id,
    string UserId,
    // Kuulla's existing stable per-install identifier (DeviceIdentity.current on iOS), reused
    // here rather than minting a second device concept — the same value already sent with every
    // sync request per docs/sync-conventions.md.
    string DeviceId,
    string ApnsToken,
    DevicePlatform Platform,
    [property: JsonProperty("updatedAt")] DateTimeOffset UpdatedAt = default)
{
    public static string BuildId(string userId, string deviceId) =>
        $"{Uri.EscapeDataString(userId)}:{Uri.EscapeDataString(deviceId)}";

    public static DeviceToken Create(string userId, string deviceId, string apnsToken, DevicePlatform platform) =>
        new(BuildId(userId, deviceId), userId, deviceId, apnsToken, platform, DateTimeOffset.UtcNow);
}

public enum DevicePlatform
{
    Ios,
}
