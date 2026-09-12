import Foundation

enum CatalogRoute: Hashable {
    case show(id: String)
    case episode(showId: String, episodeId: String)
    // Same destination as `episode`, but reached from a manual playlist — carries the playlist id
    // so EpisodeDetailView can arm PlaybackQueue for Overcast-style auto-advance on finish (#532).
    case playlistEpisode(playlistId: String, showId: String, episodeId: String)
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
