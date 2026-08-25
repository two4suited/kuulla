using Kuulla.Api.Models;

namespace Kuulla.Api.Services;

public interface IDeviceTokenService
{
    Task<DeviceToken> RegisterAsync(
        string userId, string deviceId, string apnsToken, DevicePlatform platform, CancellationToken cancellationToken);

    Task UnregisterAsync(string userId, string deviceId, CancellationToken cancellationToken);
}
