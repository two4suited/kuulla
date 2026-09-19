namespace Kuulla.Core.Models;

// Outcome of one test push to one registered device. Reason is Apple's rejection reason (or a
// local failure/config note) when Delivered is false — the point of the test push is to surface
// exactly why a device isn't receiving notifications, so it's returned rather than only logged.
public record TestPushResult(string DeviceId, bool UseSandbox, bool Delivered, string? Reason);
