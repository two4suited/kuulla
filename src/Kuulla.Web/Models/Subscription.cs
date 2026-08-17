namespace Kuulla.Web.Models;

public record Subscription(
    string Id,
    string ShowId,
    string ShowTitle,
    string ShowAuthor,
    string? ShowArtworkUrl,
    DateTimeOffset SubscribedAt);
