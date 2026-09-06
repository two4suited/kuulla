namespace Kuulla.Core.Models;

public record RegisterDeviceTokenRequest(string DeviceId, string ApnsToken, DevicePlatform Platform);
