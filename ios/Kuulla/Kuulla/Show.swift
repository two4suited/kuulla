import Foundation

struct Show: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let author: String
    let feedUrl: String
    let artworkUrl: String?
    let description: String?
    let categories: [String]
}
