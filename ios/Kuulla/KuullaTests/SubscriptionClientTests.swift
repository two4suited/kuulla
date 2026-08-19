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
        [{"id":"ep1","showId":"s1","title":"Episode One","publishedAt":"2024-01-15T10:30:00+00:00","duration":"00:45:00","audioUrl":"https://audio","description":null,"bitrateKbps":null,"fileSizeBytes":null}]
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 200, data: json, headers: [:])) }

        let episodes = try await client.getNewEpisodes()

        XCTAssertEqual(episodes.map(\.id), ["ep1"])
        let requestedURL = try XCTUnwrap(MockURLProtocol.requestedURLs.first)
        XCTAssertTrue(requestedURL.absoluteString.hasSuffix("/api/subscriptions/episodes"))
    }

    func testGetNewEpisodesReturnsEmptyOn401() async throws {
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 401, data: Data(), headers: [:])) }

        let episodes = try await client.getNewEpisodes()

        XCTAssertTrue(episodes.isEmpty)
    }
}
