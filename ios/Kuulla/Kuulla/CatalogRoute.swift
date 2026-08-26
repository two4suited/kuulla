import Foundation

enum CatalogRoute: Hashable {
    case show(id: String)
    case episode(showId: String, episodeId: String)
    case playlist(id: String)
    case upNext
    case downloads
    case discoveryCategory(id: String)
}
