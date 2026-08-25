namespace Kuulla.Api.Models;

public record RegisterDeviceTokenRequest(string DeviceId, string ApnsToken, DevicePlatform Platform);
