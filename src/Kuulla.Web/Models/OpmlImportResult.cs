namespace Kuulla.Web.Models;

// Mirrors the API's POST /api/subscriptions/import response body.
public record OpmlImportResult(
    int Added,
    int AlreadySubscribed,
    IReadOnlyList<OpmlImportFailure> Failed);

public record OpmlImportFailure(string FeedUrl, string Reason);
