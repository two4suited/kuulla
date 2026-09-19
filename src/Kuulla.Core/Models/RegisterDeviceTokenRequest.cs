namespace Kuulla.Core.Models;

// UseSandbox is optional so an older client that predates it still registers (as production).
public record RegisterDeviceTokenRequest(string DeviceId, string ApnsToken, DevicePlatform Platform, bool UseSandbox = false);
