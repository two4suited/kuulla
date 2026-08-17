import Foundation

struct SubscriptionClient {
    private let apiClient: ApiClient

    init(apiClient: ApiClient = .shared) {
        self.apiClient = apiClient
    }

    func getSubscriptions() async throws -> [Subscription] {
        try await apiClient.get("api/subscriptions")
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
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

private struct SubscribeRequest: Encodable {
    let showId: String
}
