import XCTest
@testable import Kuulla

final class SettingsClientTests: MockedApiTestCase {
    private var client: SettingsClient { SettingsClient(apiClient: apiClient) }

    func testGetSettingsDecodesResponse() async throws {
        let json = """
        {"userId":"u1","unlistenedEpisodeCount":5,"version":1}
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 200, data: json, headers: [:])) }

        let settings = try await client.getSettings()

        XCTAssertEqual(settings.unlistenedEpisodeCount, .five)
        XCTAssertEqual(settings.version, 1)
    }

    func testUpdateUnlistenedEpisodeCountSendsPutWithIntegerBody() async throws {
        let json = """
        {"userId":"u1","unlistenedEpisodeCount":10,"version":2}
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 200, data: json, headers: [:])) }

        let updated = try await client.updateUnlistenedEpisodeCount(.ten)

        XCTAssertEqual(updated.unlistenedEpisodeCount, .ten)
        let request = try XCTUnwrap(MockURLProtocol.requestedURLs.first)
        XCTAssertTrue(request.absoluteString.hasSuffix("/api/settings"))
    }

    func testGetShowSettingsDecodesNullOverrideAsNil() async throws {
        let json = """
        {"id":"show:u1:s1","userId":"u1","showId":"s1","unlistenedEpisodeCount":null,"version":1}
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 200, data: json, headers: [:])) }

        let settings = try await client.getShowSettings(showId: "s1")

        XCTAssertNil(settings.unlistenedEpisodeCount)
    }

    func testUpdateShowUnlistenedEpisodeCountClearsOverrideWithNil() async throws {
        let json = """
        {"id":"show:u1:s1","userId":"u1","showId":"s1","unlistenedEpisodeCount":null,"version":3}
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 200, data: json, headers: [:])) }

        let updated = try await client.updateShowUnlistenedEpisodeCount(showId: "s1", value: nil)

        XCTAssertNil(updated.unlistenedEpisodeCount)
        XCTAssertEqual(updated.version, 3)
    }

    func testUpdateShowUnlistenedEpisodeCountEscapesShowIdInPath() async throws {
        let json = """
        {"id":"show:u1:a%2Fb","userId":"u1","showId":"a/b","unlistenedEpisodeCount":1,"version":1}
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 200, data: json, headers: [:])) }

        _ = try await client.updateShowUnlistenedEpisodeCount(showId: "a/b", value: .one)

        let requestedURL = try XCTUnwrap(MockURLProtocol.requestedURLs.first)
        XCTAssertTrue(requestedURL.absoluteString.contains("a%2Fb"))
    }
}
