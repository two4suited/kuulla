import Foundation

struct SubscriptionClient {
    private let apiClient: ApiClient

    init(apiClient: ApiClient = .shared) {
        self.apiClient = apiClient
    }

    func getSubscriptions() async throws -> [Subscription] {
        do {
            return try await apiClient.get(["api", "subscriptions"])
        } catch ApiError.requestFailed(let statusCode) where statusCode == 401 || statusCode == 403 {
            // Mirrors the web client: an unauthenticated caller has no subscriptions rather than an error.
            return []
        }
    }

    func subscribe(showId: String) async throws -> Subscription {
        try await apiClient.post(["api", "subscriptions"], body: SubscribeRequest(showId: showId))
    }

    func unsubscribe(showId: String) async throws {
        try await apiClient.delete(["api", "subscriptions", showId])
    }

    func getNewEpisodes() async throws -> [NewEpisode] {
        do {
            return try await apiClient.get(["api", "subscriptions", "episodes"])
        } catch ApiError.requestFailed(let statusCode) where statusCode == 401 || statusCode == 403 {
            // Mirrors getSubscriptions(): an unauthenticated caller has no feed rather than an error.
            return []
        }
    }
}

private struct SubscribeRequest: Encodable {
    let showId: String
}

// Wire shape is { episode, autoPlayed } per item (#98/#99). autoPlayed episodes were marked played
// by the unlistened-episode-limit enforcement job rather than the user, so callers computing an
// "unplayed" count or list must exclude them — mirrors EpisodeStateClient on Web.
struct NewEpisode: Decodable {
    let episode: Episode
    let autoPlayed: Bool
}
