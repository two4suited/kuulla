namespace Kuulla.Core.Models;

// ShowIds is the full ordered subscription list for SubscriptionSortOrder.Manual (#438), sent
// wholesale on every reorder. An empty list clears the manual arrangement.
public record UpdateSubscriptionManualOrderRequest(IReadOnlyList<string> ShowIds);
