import Foundation

enum CatalogRoute: Hashable {
    case show(id: String)
    case episode(showId: String, episodeId: String)
}
