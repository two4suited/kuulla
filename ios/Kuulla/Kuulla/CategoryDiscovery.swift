import Foundation

struct CategoryDiscovery: Decodable {
    let category: DiscoveryCategory
    let trending: [Show]
}
