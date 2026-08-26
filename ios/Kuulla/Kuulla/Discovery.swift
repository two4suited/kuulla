import Foundation

struct Discovery: Decodable {
    let categories: [DiscoveryCategory]
    let trending: [Show]
}
