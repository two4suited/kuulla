import Foundation

// Episode-state REST calls that aren't part of the SwiftData sync loop. Per-episode playback
// position/completion still flows through EpisodeSyncAdapter (POST /api/sync/episodes); this
// covers bulk actions the sync push can't express, like "mark every episode of a show played"
// (#490), which must reach the show's whole back catalogue on the server rather than only the
// episodes this device happens to have loaded.
struct EpisodeStateClient {
    private let apiClient: ApiClient

    init(apiClient: ApiClient = .shared) {
        self.apiClient = apiClient
    }

    // POST /api/shows/{showId}/episode-state/mark-all-played. The server marks every episode it
    // knows for the show played for the caller and stamps each row for sync; callers should
    // follow with a sync pull so the local store converges. Idempotent — a re-run reports
    // updatedCount == 0.
    @discardableResult
    func markAllPlayed(showId: String) async throws -> MarkAllPlayedResult {
        try await apiClient.post(
            ["api", "shows", showId, "episode-state", "mark-all-played"],
            body: MarkAllPlayedRequest(deviceId: DeviceIdentity.current))
    }
}

private struct MarkAllPlayedRequest: Encodable {
    let deviceId: String
}

// Wire shape of the mark-all-played response. The updated rows themselves are pulled in via the
// normal episode-state sync, so only the counts are decoded here.
struct MarkAllPlayedResult: Decodable {
    let totalEpisodes: Int
    let updatedCount: Int
}
