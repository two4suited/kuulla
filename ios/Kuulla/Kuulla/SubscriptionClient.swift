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

    // Shows the user has at least one in-progress episode for — pairs with getNewEpisodes() to
    // decide which shows are "caught up" for the hide/sink behavior (#438 follow-up). Mirrors
    // EpisodeStateClient.GetInProgressShowIdsAsync on Web.
    func getInProgressShowIds() async throws -> Set<String> {
        do {
            let ids: [String] = try await apiClient.get(["api", "episodes", "in-progress-shows"])
            return Set(ids)
        } catch ApiError.requestFailed(let statusCode) where statusCode == 401 || statusCode == 403 {
            return []
        }
    }
}

private struct SubscribeRequest: Encodable {
    let showId: String
}

// Wire shape is { episode, autoPlayed, showTitle, showArtworkUrl } per item (#98/#99, #441).
// autoPlayed episodes were marked played by the unlistened-episode-limit enforcement job rather
// than the user, so callers computing an "unplayed" count or list must exclude them — mirrors
// EpisodeStateClient on Web. showTitle/showArtworkUrl are snapshotted from the subscription so the
// New Episodes list can identify which podcast each row is from.
struct NewEpisode: Decodable {
    let episode: Episode
    let autoPlayed: Bool
    let showTitle: String
    let showArtworkUrl: String?

    private enum CodingKeys: String, CodingKey {
        case episode, autoPlayed, showTitle, showArtworkUrl
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        episode = try container.decode(Episode.self, forKey: .episode)
        autoPlayed = try container.decode(Bool.self, forKey: .autoPlayed)
        // Tolerate an older API that doesn't send show identity yet rather than failing the whole
        // decode — the row falls back to a placeholder and the episode title alone.
        showTitle = try container.decodeIfPresent(String.self, forKey: .showTitle) ?? ""
        showArtworkUrl = try container.decodeIfPresent(String.self, forKey: .showArtworkUrl)
    }
}
