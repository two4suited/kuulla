import Foundation

struct EpisodePage: Decodable {
    let items: [Episode]
    let continuationToken: String?
}
