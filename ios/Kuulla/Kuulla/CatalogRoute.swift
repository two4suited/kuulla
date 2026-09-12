import Foundation

enum CatalogRoute: Hashable {
    case show(id: String)
    // autoPlay: true starts playback immediately once EpisodeDetailView loads — set by a list
    // row's play button so tapping it doesn't require a second tap on the detail screen. list, when
    // the screen that pushed this route already had its ordered snapshot on hand (ShowDetailView,
    // FeedView), lets EpisodeDetailView arm PlaybackQueue for auto-advance (#629) without a
    // re-fetch.
    case episode(showId: String, episodeId: String, autoPlay: Bool = false, list: PlaybackList? = nil)
    // Same destination as `episode`, but reached from a manual playlist — carries the playlist id
    // so EpisodeDetailView can arm PlaybackQueue for Overcast-style auto-advance on finish (#532).
    case playlistEpisode(playlistId: String, showId: String, episodeId: String, autoPlay: Bool = false)
    case playlist(id: String)
    case upNext
    case downloads
    case discoveryCategory(id: String)
    case settings
}

extension CatalogRoute: Identifiable {
    // Hashable already gives every case structural equality, so the case itself is a fine id —
    // no need for a synthesized UUID or a separate switch to a string key.
    var id: Self { self }
}
