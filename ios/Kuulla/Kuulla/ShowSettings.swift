import Foundation

// A user's per-show override of their global UnlistenedEpisodeCount setting.
// unlistenedEpisodeCount is nil when there's no override — inherit the user's global setting.
struct ShowSettings: Codable, Hashable {
    let id: String
    let userId: String
    let showId: String
    let unlistenedEpisodeCount: UnlistenedEpisodeCount?
    let version: Int
}
