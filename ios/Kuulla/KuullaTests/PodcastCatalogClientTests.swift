import XCTest
@testable import Kuulla

final class PodcastCatalogClientTests: MockedApiTestCase {
    private var client: PodcastCatalogClient { PodcastCatalogClient(apiClient: apiClient) }

    func testGetShowReturnsNilOn404() async throws {
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 404, data: Data(), headers: [:])) }

        let show = try await client.getShow(id: "missing")

        XCTAssertNil(show)
    }

    func testGetShowDecodesShow() async throws {
        let json = """
        {"id":"1","title":"T","author":"A","feedUrl":"https://feed","artworkUrl":null,"description":null,"categories":[]}
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 200, data: json, headers: [:])) }

        let show = try await client.getShow(id: "1")

        XCTAssertEqual(show?.title, "T")
    }

    func testGetEpisodeReturnsNilOn404() async throws {
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 404, data: Data(), headers: [:])) }

        let episode = try await client.getEpisode(showId: "1", episodeId: "missing")

        XCTAssertNil(episode)
    }

    func testGetEpisodesIncludesContinuationTokenAndPageSize() async throws {
        let json = """
        {"items":[],"continuationToken":null}
        """.data(using: .utf8)!
        var capturedURL: URL?
        MockURLProtocol.stubHandler = { request in
            capturedURL = request.url
            return .success(.init(statusCode: 200, data: json, headers: [:]))
        }

        _ = try await client.getEpisodes(showId: "1", continuationToken: "abc", pageSize: 5)

        let query = try XCTUnwrap(capturedURL?.query)
        XCTAssertTrue(query.contains("continuationToken=abc"))
        XCTAssertTrue(query.contains("pageSize=5"))
    }

    func testGetEpisodesOmitsContinuationTokenWhenNil() async throws {
        let json = """
        {"items":[],"continuationToken":null}
        """.data(using: .utf8)!
        var capturedURL: URL?
        MockURLProtocol.stubHandler = { request in
            capturedURL = request.url
            return .success(.init(statusCode: 200, data: json, headers: [:]))
        }

        _ = try await client.getEpisodes(showId: "1", continuationToken: nil)

        let query = try XCTUnwrap(capturedURL?.query)
        XCTAssertFalse(query.contains("continuationToken"))
    }

    func testSearchShowsPassesQuery() async throws {
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 200, data: "[]".data(using: .utf8)!, headers: [:])) }

        _ = try await client.searchShows(query: "test")

        let requestedURL = try XCTUnwrap(MockURLProtocol.requestedURLs.first)
        XCTAssertEqual(requestedURL.query, "q=test")
    }

    func testGetDiscoveryDecodesCategoriesAndTrending() async throws {
        let json = """
        {"categories":[{"id":"1301","name":"Arts"}],"trending":[{"id":"1","title":"T","author":"A","feedUrl":"https://feed","artworkUrl":null,"description":null,"categories":[]}]}
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 200, data: json, headers: [:])) }

        let discovery = try await client.getDiscovery()

        XCTAssertEqual(discovery.categories.first?.name, "Arts")
        XCTAssertEqual(discovery.trending.first?.title, "T")
        let requestedURL = try XCTUnwrap(MockURLProtocol.requestedURLs.first)
        XCTAssertEqual(requestedURL.path, "/api/discovery")
    }

    func testGetCategoryDiscoveryReturnsNilOn404() async throws {
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 404, data: Data(), headers: [:])) }

        let result = try await client.getCategoryDiscovery(categoryId: "missing")

        XCTAssertNil(result)
    }

    func testGetCategoryDiscoveryDecodesCategoryAndTrending() async throws {
        let json = """
        {"category":{"id":"1301","name":"Arts"},"trending":[{"id":"1","title":"T","author":"A","feedUrl":"https://feed","artworkUrl":null,"description":null,"categories":[]}]}
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 200, data: json, headers: [:])) }

        let result = try await client.getCategoryDiscovery(categoryId: "1301")

        XCTAssertEqual(result?.category.name, "Arts")
        XCTAssertEqual(result?.trending.first?.title, "T")
        let requestedURL = try XCTUnwrap(MockURLProtocol.requestedURLs.first)
        XCTAssertEqual(requestedURL.path, "/api/discovery/categories/1301")
    }
}
