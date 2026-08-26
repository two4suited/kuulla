import Foundation

struct PodcastCatalogClient {
    private let apiClient: ApiClient

    init(apiClient: ApiClient = .shared) {
        self.apiClient = apiClient
    }

    func searchShows(query: String) async throws -> [Show] {
        try await apiClient.get(["api", "shows", "search"], queryItems: [URLQueryItem(name: "q", value: query)])
    }

    func getShow(id: String) async throws -> Show? {
        do {
            return try await apiClient.get(["api", "shows", id])
        } catch ApiError.requestFailed(statusCode: 404) {
            return nil
        }
    }

    func getEpisodes(showId: String, continuationToken: String?, pageSize: Int = 20) async throws -> EpisodePage {
        var queryItems = [URLQueryItem(name: "pageSize", value: String(pageSize))]
        if let continuationToken {
            queryItems.append(URLQueryItem(name: "continuationToken", value: continuationToken))
        }
        return try await apiClient.get(["api", "shows", showId, "episodes"], queryItems: queryItems)
    }

    func getEpisode(showId: String, episodeId: String) async throws -> Episode? {
        do {
            return try await apiClient.get(["api", "shows", showId, "episodes", episodeId])
        } catch ApiError.requestFailed(statusCode: 404) {
            return nil
        }
    }

    func getDiscovery() async throws -> Discovery {
        try await apiClient.get(["api", "discovery"])
    }

    func getCategoryDiscovery(categoryId: String) async throws -> CategoryDiscovery? {
        do {
            return try await apiClient.get(["api", "discovery", "categories", categoryId])
        } catch ApiError.requestFailed(statusCode: 404) {
            return nil
        }
    }
}
