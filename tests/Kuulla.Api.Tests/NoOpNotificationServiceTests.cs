using Kuulla.Core.Models;
using Kuulla.Core.Services;

namespace Kuulla.Api.Tests;

public class NoOpNotificationServiceTests
{
    [Fact]
    public async Task SendTestNotificationAsync_ReportsEachDeviceAsNotDeliveredBecauseApnsIsUnconfigured()
    {
        var token = new DeviceToken("u:d1", "u", "d1", "apns-token", DevicePlatform.Ios, UseSandbox: true);

        var results = await new NoOpNotificationService().SendTestNotificationAsync([token], CancellationToken.None);

        var result = Assert.Single(results);
        Assert.Equal("d1", result.DeviceId);
        Assert.False(result.Delivered);
        Assert.Contains("not configured", result.Reason);
    }
}
