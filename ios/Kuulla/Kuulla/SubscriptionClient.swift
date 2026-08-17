import Foundation

struct SubscriptionClient {
    private let apiClient: ApiClient

    init(apiClient: ApiClient = .shared) {
        self.apiClient = apiClient
    }

    func getSubscriptions() async throws -> [Subscription] {
        try await apiClient.get("api/subscriptions")
    }
}
