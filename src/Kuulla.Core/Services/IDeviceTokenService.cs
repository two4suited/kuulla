using Kuulla.Core.Models;

namespace Kuulla.Core.Services;

public interface IDeviceTokenService
{
    Task<DeviceToken> RegisterAsync(
        string userId, string deviceId, string apnsToken, DevicePlatform platform, bool useSandbox, CancellationToken cancellationToken);

    Task UnregisterAsync(string userId, string deviceId, CancellationToken cancellationToken);

    // Single-partition read (devicetokens is partitioned by UserId) — every device a user has
    // registered, for the push-send path to fan a notification out to.
    Task<IReadOnlyList<DeviceToken>> GetTokensForUserAsync(string userId, CancellationToken cancellationToken);
}
