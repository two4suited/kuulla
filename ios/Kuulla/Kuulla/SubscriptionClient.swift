import Foundation

struct SubscriptionClient {
    private let apiClient: ApiClient

    init(apiClient: ApiClient = .shared) {
        self.apiClient = apiClient
    }

    func getSubscriptions() async throws -> [Subscription] {
        do {
            return try await apiClient.get("api/subscriptions")
        } catch ApiError.requestFailed(let statusCode) where statusCode == 401 || statusCode == 403 {
            // Mirrors the web client: an unauthenticated caller has no subscriptions rather than an error.
            return []
        }
    }

    func subscribe(showId: String) async throws -> Subscription {
        try await apiClient.post("api/subscriptions", body: SubscribeRequest(showId: showId))
    }

    func unsubscribe(showId: String) async throws {
        try await apiClient.delete("api/subscriptions/\(Self.pathEscaped(showId))")
    }

    // Escapes showId as a single path segment, unlike CharacterSet.urlPathAllowed which
    // leaves "/" unescaped and would let a slash in the id split the URL into extra segments.
    private static func pathEscaped(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        // Fall back to a manual "/" escape rather than the raw value, so a malformed/edge-case
        // id still can't split the request path into extra segments.
        return value.addingPercentEncoding(withAllowedCharacters: allowed)
            ?? value.replacingOccurrences(of: "/", with: "%2F")
    }
}

private struct SubscribeRequest: Encodable {
    let showId: String
}
