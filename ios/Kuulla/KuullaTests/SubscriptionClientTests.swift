import XCTest
@testable import Kuulla

final class SubscriptionClientTests: MockedApiTestCase {
    private var client: SubscriptionClient { SubscriptionClient(apiClient: apiClient) }

    func testGetSubscriptionsReturnsEmptyOn401() async throws {
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 401, data: Data(), headers: [:])) }

        let subscriptions = try await client.getSubscriptions()

        XCTAssertEqual(subscriptions, [])
    }

    func testGetSubscriptionsReturnsEmptyOn403() async throws {
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 403, data: Data(), headers: [:])) }

        let subscriptions = try await client.getSubscriptions()

        XCTAssertEqual(subscriptions, [])
    }

    func testGetSubscriptionsPropagatesOtherErrors() async {
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 500, data: Data(), headers: [:])) }

        do {
            _ = try await client.getSubscriptions()
            XCTFail("expected ApiError.requestFailed")
        } catch ApiError.requestFailed(let statusCode) {
            XCTAssertEqual(statusCode, 500)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testSubscribeDecodesResponse() async throws {
        let json = """
        {"id":"1","userId":"u1","showId":"s1","showTitle":"T","showAuthor":"A","showArtworkUrl":null,"subscribedAt":"2024-01-15T10:30:00+00:00"}
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 200, data: json, headers: [:])) }

        let subscription = try await client.subscribe(showId: "s1")

        XCTAssertEqual(subscription.showId, "s1")
    }

    func testUnsubscribeEscapesSlashInShowId() async throws {
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 204, data: Data(), headers: [:])) }

        try await client.unsubscribe(showId: "a/b")

        let requestedURL = try XCTUnwrap(MockURLProtocol.requestedURLs.first)
        XCTAssertTrue(requestedURL.absoluteString.contains("a%2Fb"))
    }

    func testGetNewEpisodesDecodesResponse() async throws {
        let json = """
        [{"episode":{"id":"ep1","showId":"s1","title":"Episode One","publishedAt":"2024-01-15T10:30:00+00:00","duration":"00:45:00","audioUrl":"https://audio","description":null,"bitrateKbps":null,"fileSizeBytes":null},"autoPlayed":false,"showTitle":"The Daily Show","showArtworkUrl":"https://art/s1.jpg"}]
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 200, data: json, headers: [:])) }

        let episodes = try await client.getNewEpisodes()

        XCTAssertEqual(episodes.map(\.episode.id), ["ep1"])
        XCTAssertEqual(episodes.map(\.autoPlayed), [false])
        XCTAssertEqual(episodes.map(\.showTitle), ["The Daily Show"])
        XCTAssertEqual(episodes.map(\.showArtworkUrl), ["https://art/s1.jpg"])
        let requestedURL = try XCTUnwrap(MockURLProtocol.requestedURLs.first)
        XCTAssertTrue(requestedURL.absoluteString.hasSuffix("/api/subscriptions/episodes"))
    }

    func testGetNewEpisodesToleratesMissingShowIdentity() async throws {
        let json = """
        [{"episode":{"id":"ep1","showId":"s1","title":"Episode One","publishedAt":null,"duration":null,"audioUrl":"https://audio","description":null,"bitrateKbps":null,"fileSizeBytes":null},"autoPlayed":false}]
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 200, data: json, headers: [:])) }

        let episodes = try await client.getNewEpisodes()

        XCTAssertEqual(episodes.map(\.showTitle), [""])
        XCTAssertNil(episodes[0].showArtworkUrl)
    }

    func testGetNewEpisodesReturnsEmptyOn401() async throws {
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 401, data: Data(), headers: [:])) }

        let episodes = try await client.getNewEpisodes()

        XCTAssertTrue(episodes.isEmpty)
    }

    func testGetInProgressShowIdsDecodesResponse() async throws {
        let json = #"["show-a","show-b"]"#.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 200, data: json, headers: [:])) }

        let ids = try await client.getInProgressShowIds()

        XCTAssertEqual(ids, ["show-a", "show-b"])
        let requestedURL = try XCTUnwrap(MockURLProtocol.requestedURLs.first)
        XCTAssertTrue(requestedURL.absoluteString.hasSuffix("/api/episodes/in-progress-shows"))
    }

    func testGetInProgressShowIdsReturnsEmptyOn403() async throws {
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 403, data: Data(), headers: [:])) }

        let ids = try await client.getInProgressShowIds()

        XCTAssertTrue(ids.isEmpty)
    }
}
