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
        var capturedMethod: String?
        var capturedBody: Data?
        MockURLProtocol.stubHandler = { request in
            capturedMethod = request.httpMethod
            capturedBody = request.capturedBodyData
            return .success(.init(statusCode: 200, data: json, headers: [:]))
        }

        let updated = try await client.updateUnlistenedEpisodeCount(.ten)

        XCTAssertEqual(updated.unlistenedEpisodeCount, .ten)
        let requestedURL = try XCTUnwrap(MockURLProtocol.requestedURLs.first)
        XCTAssertTrue(requestedURL.absoluteString.hasSuffix("/api/settings"))
        XCTAssertEqual(capturedMethod, "PUT")
        let bodyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(capturedBody)) as? [String: Any])
        XCTAssertEqual(bodyJSON["unlistenedEpisodeCount"] as? Int, 10)
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

    func testGetSettingsDefaultsAutoArchiveRuleToNeverWhenAbsent() async throws {
        let json = """
        {"userId":"u1","unlistenedEpisodeCount":5,"version":1}
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 200, data: json, headers: [:])) }

        let settings = try await client.getSettings()

        XCTAssertEqual(settings.autoArchiveRule, .never)
    }

    func testUpdateAutoArchiveRuleSendsPutWithIntegerBody() async throws {
        let json = """
        {"userId":"u1","unlistenedEpisodeCount":5,"version":2,"autoArchiveRule":3}
        """.data(using: .utf8)!
        var capturedMethod: String?
        var capturedBody: Data?
        MockURLProtocol.stubHandler = { request in
            capturedMethod = request.httpMethod
            capturedBody = request.capturedBodyData
            return .success(.init(statusCode: 200, data: json, headers: [:]))
        }

        let updated = try await client.updateAutoArchiveRule(.after7Days)

        XCTAssertEqual(updated.autoArchiveRule, .after7Days)
        let requestedURL = try XCTUnwrap(MockURLProtocol.requestedURLs.first)
        XCTAssertTrue(requestedURL.absoluteString.hasSuffix("/api/settings/auto-archive"))
        XCTAssertEqual(capturedMethod, "PUT")
        let bodyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(capturedBody)) as? [String: Any])
        XCTAssertEqual(bodyJSON["autoArchiveRule"] as? Int, 3)
    }

    func testGetShowSettingsDecodesNullAutoArchiveRuleOverrideAsNil() async throws {
        let json = """
        {"id":"show:u1:s1","userId":"u1","showId":"s1","unlistenedEpisodeCount":null,"version":1,"autoArchiveRule":null}
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 200, data: json, headers: [:])) }

        let settings = try await client.getShowSettings(showId: "s1")

        XCTAssertNil(settings.autoArchiveRule)
    }

    func testUpdateShowAutoArchiveRuleClearsOverrideWithNil() async throws {
        let json = """
        {"id":"show:u1:s1","userId":"u1","showId":"s1","unlistenedEpisodeCount":null,"version":3,"autoArchiveRule":null}
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 200, data: json, headers: [:])) }

        let updated = try await client.updateShowAutoArchiveRule(showId: "s1", value: nil)

        XCTAssertNil(updated.autoArchiveRule)
        XCTAssertEqual(updated.version, 3)
    }

    func testGetSettingsDefaultsAutoSkipSecondsToZeroWhenAbsent() async throws {
        let json = """
        {"userId":"u1","unlistenedEpisodeCount":5,"version":1}
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 200, data: json, headers: [:])) }

        let settings = try await client.getSettings()

        XCTAssertEqual(settings.autoSkipIntroSeconds, 0)
        XCTAssertEqual(settings.autoSkipOutroSeconds, 0)
    }

    func testUpdateAutoSkipSendsPutWithIntegerBody() async throws {
        let json = """
        {"userId":"u1","unlistenedEpisodeCount":5,"version":2,"autoSkipIntroSeconds":15,"autoSkipOutroSeconds":30}
        """.data(using: .utf8)!
        var capturedMethod: String?
        var capturedBody: Data?
        MockURLProtocol.stubHandler = { request in
            capturedMethod = request.httpMethod
            capturedBody = request.capturedBodyData
            return .success(.init(statusCode: 200, data: json, headers: [:]))
        }

        let updated = try await client.updateAutoSkip(introSeconds: 15, outroSeconds: 30)

        XCTAssertEqual(updated.autoSkipIntroSeconds, 15)
        XCTAssertEqual(updated.autoSkipOutroSeconds, 30)
        let requestedURL = try XCTUnwrap(MockURLProtocol.requestedURLs.first)
        XCTAssertTrue(requestedURL.absoluteString.hasSuffix("/api/settings/auto-skip"))
        XCTAssertEqual(capturedMethod, "PUT")
        let bodyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(capturedBody)) as? [String: Any])
        XCTAssertEqual(bodyJSON["autoSkipIntroSeconds"] as? Int, 15)
        XCTAssertEqual(bodyJSON["autoSkipOutroSeconds"] as? Int, 30)
    }

    func testGetShowSettingsDecodesNullAutoSkipOverridesAsNil() async throws {
        let json = """
        {"id":"show:u1:s1","userId":"u1","showId":"s1","unlistenedEpisodeCount":null,"version":1,\
        "autoSkipIntroSeconds":null,"autoSkipOutroSeconds":null}
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 200, data: json, headers: [:])) }

        let settings = try await client.getShowSettings(showId: "s1")

        XCTAssertNil(settings.autoSkipIntroSeconds)
        XCTAssertNil(settings.autoSkipOutroSeconds)
    }

    func testUpdateShowAutoSkipClearsOverridesWithNil() async throws {
        let json = """
        {"id":"show:u1:s1","userId":"u1","showId":"s1","unlistenedEpisodeCount":null,"version":3,\
        "autoSkipIntroSeconds":null,"autoSkipOutroSeconds":null}
        """.data(using: .utf8)!
        var capturedBody: Data?
        MockURLProtocol.stubHandler = { request in
            capturedBody = request.capturedBodyData
            return .success(.init(statusCode: 200, data: json, headers: [:]))
        }

        let updated = try await client.updateShowAutoSkip(showId: "s1", introSeconds: nil, outroSeconds: nil)

        XCTAssertNil(updated.autoSkipIntroSeconds)
        XCTAssertNil(updated.autoSkipOutroSeconds)
        let requestedURL = try XCTUnwrap(MockURLProtocol.requestedURLs.first)
        XCTAssertTrue(requestedURL.absoluteString.hasSuffix("/api/settings/shows/s1/auto-skip"))
        // A nil Optional<Int> is omitted from the encoded JSON entirely (not sent as an explicit
        // null) — the API's nullable-int deserialization treats a missing key the same as null,
        // so either representation clears the override.
        let bodyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(capturedBody)) as? [String: Any])
        XCTAssertNil(bodyJSON["autoSkipIntroSeconds"])
        XCTAssertNil(bodyJSON["autoSkipOutroSeconds"])
    }

    func testGetSettingsDefaultsPlaybackSpeedToNormalWhenAbsent() async throws {
        let json = """
        {"userId":"u1","unlistenedEpisodeCount":5,"version":1}
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 200, data: json, headers: [:])) }

        let settings = try await client.getSettings()

        XCTAssertEqual(settings.playbackSpeed, 1.0)
    }

    func testUpdatePlaybackSpeedSendsPutWithFloatBody() async throws {
        let json = """
        {"userId":"u1","unlistenedEpisodeCount":5,"version":2,"playbackSpeed":1.5}
        """.data(using: .utf8)!
        var capturedMethod: String?
        var capturedBody: Data?
        MockURLProtocol.stubHandler = { request in
            capturedMethod = request.httpMethod
            capturedBody = request.capturedBodyData
            return .success(.init(statusCode: 200, data: json, headers: [:]))
        }

        let updated = try await client.updatePlaybackSpeed(1.5)

        XCTAssertEqual(updated.playbackSpeed, 1.5)
        let requestedURL = try XCTUnwrap(MockURLProtocol.requestedURLs.first)
        XCTAssertTrue(requestedURL.absoluteString.hasSuffix("/api/settings/playback-speed"))
        XCTAssertEqual(capturedMethod, "PUT")
        let bodyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(capturedBody)) as? [String: Any])
        // JSONSerialization decodes numeric values as NSNumber/Double, not Float — `as? Float`
        // would fail to cast (nil), failing this assertion even though the body is correct.
        XCTAssertEqual(bodyJSON["playbackSpeed"] as? Double, 1.5)
    }

    func testGetShowSettingsDecodesNullPlaybackSpeedOverrideAsNil() async throws {
        let json = """
        {"id":"show:u1:s1","userId":"u1","showId":"s1","unlistenedEpisodeCount":null,"version":1,"playbackSpeed":null}
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 200, data: json, headers: [:])) }

        let settings = try await client.getShowSettings(showId: "s1")

        XCTAssertNil(settings.playbackSpeed)
    }

    func testUpdateShowPlaybackSpeedClearsOverrideWithNil() async throws {
        let json = """
        {"id":"show:u1:s1","userId":"u1","showId":"s1","unlistenedEpisodeCount":null,"version":3,"playbackSpeed":null}
        """.data(using: .utf8)!
        var capturedBody: Data?
        MockURLProtocol.stubHandler = { request in
            capturedBody = request.capturedBodyData
            return .success(.init(statusCode: 200, data: json, headers: [:]))
        }

        let updated = try await client.updateShowPlaybackSpeed(showId: "s1", value: nil)

        XCTAssertNil(updated.playbackSpeed)
        XCTAssertEqual(updated.version, 3)
        let requestedURL = try XCTUnwrap(MockURLProtocol.requestedURLs.first)
        XCTAssertTrue(requestedURL.absoluteString.hasSuffix("/api/settings/shows/s1/playback-speed"))
        let bodyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(capturedBody)) as? [String: Any])
        XCTAssertNil(bodyJSON["playbackSpeed"])
    }

    func testGetSettingsDefaultsAutoDeleteRuleToNeverWhenAbsent() async throws {
        let json = """
        {"userId":"u1","unlistenedEpisodeCount":5,"version":1}
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 200, data: json, headers: [:])) }

        let settings = try await client.getSettings()

        XCTAssertEqual(settings.autoDeleteRule, .never)
        XCTAssertEqual(settings.autoDeleteAfterDays, 7)
    }

    func testUpdateAutoDeleteRuleSendsPutWithIntegerBody() async throws {
        let json = """
        {"userId":"u1","unlistenedEpisodeCount":5,"version":2,"autoDeleteRule":1,"autoDeleteAfterDays":14}
        """.data(using: .utf8)!
        var capturedMethod: String?
        var capturedBody: Data?
        MockURLProtocol.stubHandler = { request in
            capturedMethod = request.httpMethod
            capturedBody = request.capturedBodyData
            return .success(.init(statusCode: 200, data: json, headers: [:]))
        }

        let updated = try await client.updateAutoDeleteRule(.afterPlayed, afterDays: 14)

        XCTAssertEqual(updated.autoDeleteRule, .afterPlayed)
        XCTAssertEqual(updated.autoDeleteAfterDays, 14)
        let requestedURL = try XCTUnwrap(MockURLProtocol.requestedURLs.first)
        XCTAssertTrue(requestedURL.absoluteString.hasSuffix("/api/settings/auto-delete"))
        XCTAssertEqual(capturedMethod, "PUT")
        let bodyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(capturedBody)) as? [String: Any])
        XCTAssertEqual(bodyJSON["autoDeleteRule"] as? Int, 1)
        XCTAssertEqual(bodyJSON["autoDeleteAfterDays"] as? Int, 14)
    }

    func testGetSettingsDefaultsAutoDownloadNewEpisodesToFalseWhenAbsent() async throws {
        let json = """
        {"userId":"u1","unlistenedEpisodeCount":5,"version":1}
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 200, data: json, headers: [:])) }

        let settings = try await client.getSettings()

        XCTAssertFalse(settings.autoDownloadNewEpisodes)
    }

    func testUpdateAutoDownloadNewEpisodesSendsPutWithBooleanBody() async throws {
        let json = """
        {"userId":"u1","unlistenedEpisodeCount":5,"version":2,"autoDownloadNewEpisodes":true}
        """.data(using: .utf8)!
        var capturedMethod: String?
        var capturedBody: Data?
        MockURLProtocol.stubHandler = { request in
            capturedMethod = request.httpMethod
            capturedBody = request.capturedBodyData
            return .success(.init(statusCode: 200, data: json, headers: [:]))
        }

        let updated = try await client.updateAutoDownloadNewEpisodes(true)

        XCTAssertTrue(updated.autoDownloadNewEpisodes)
        let requestedURL = try XCTUnwrap(MockURLProtocol.requestedURLs.first)
        XCTAssertTrue(requestedURL.absoluteString.hasSuffix("/api/settings/auto-download"))
        XCTAssertEqual(capturedMethod, "PUT")
        let bodyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(capturedBody)) as? [String: Any])
        XCTAssertEqual(bodyJSON["autoDownloadNewEpisodes"] as? Bool, true)
    }

    func testGetShowSettingsDecodesNullAutoDownloadOverrideAsNil() async throws {
        let json = """
        {"id":"show:u1:s1","userId":"u1","showId":"s1","unlistenedEpisodeCount":null,"version":1,"autoDownloadNewEpisodes":null}
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 200, data: json, headers: [:])) }

        let settings = try await client.getShowSettings(showId: "s1")

        XCTAssertNil(settings.autoDownloadNewEpisodes)
    }

    func testUpdateShowAutoDownloadNewEpisodesClearsOverrideWithNil() async throws {
        let json = """
        {"id":"show:u1:s1","userId":"u1","showId":"s1","unlistenedEpisodeCount":null,"version":3,"autoDownloadNewEpisodes":null}
        """.data(using: .utf8)!
        var capturedBody: Data?
        MockURLProtocol.stubHandler = { request in
            capturedBody = request.capturedBodyData
            return .success(.init(statusCode: 200, data: json, headers: [:]))
        }

        let updated = try await client.updateShowAutoDownloadNewEpisodes(showId: "s1", value: nil)

        XCTAssertNil(updated.autoDownloadNewEpisodes)
        XCTAssertEqual(updated.version, 3)
        let requestedURL = try XCTUnwrap(MockURLProtocol.requestedURLs.first)
        XCTAssertTrue(requestedURL.absoluteString.hasSuffix("/api/settings/shows/s1/auto-download"))
        let bodyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(capturedBody)) as? [String: Any])
        XCTAssertNil(bodyJSON["autoDownloadNewEpisodes"])
    }

    func testGetSettingsDefaultsSmartSpeedToFalseWhenAbsent() async throws {
        let json = """
        {"userId":"u1","unlistenedEpisodeCount":5,"version":1}
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 200, data: json, headers: [:])) }

        let settings = try await client.getSettings()

        XCTAssertFalse(settings.smartSpeed)
    }

    func testUpdateSmartSpeedSendsPutWithBooleanBody() async throws {
        let json = """
        {"userId":"u1","unlistenedEpisodeCount":5,"version":2,"smartSpeed":true}
        """.data(using: .utf8)!
        var capturedMethod: String?
        var capturedBody: Data?
        MockURLProtocol.stubHandler = { request in
            capturedMethod = request.httpMethod
            capturedBody = request.capturedBodyData
            return .success(.init(statusCode: 200, data: json, headers: [:]))
        }

        let updated = try await client.updateSmartSpeed(true)

        XCTAssertTrue(updated.smartSpeed)
        let requestedURL = try XCTUnwrap(MockURLProtocol.requestedURLs.first)
        XCTAssertTrue(requestedURL.absoluteString.hasSuffix("/api/settings/smart-speed"))
        XCTAssertEqual(capturedMethod, "PUT")
        let bodyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(capturedBody)) as? [String: Any])
        XCTAssertEqual(bodyJSON["smartSpeed"] as? Bool, true)
    }

    func testGetShowSettingsDecodesNullSmartSpeedOverrideAsNil() async throws {
        let json = """
        {"id":"show:u1:s1","userId":"u1","showId":"s1","unlistenedEpisodeCount":null,"version":1,"smartSpeed":null}
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 200, data: json, headers: [:])) }

        let settings = try await client.getShowSettings(showId: "s1")

        XCTAssertNil(settings.smartSpeed)
    }

    func testUpdateShowSmartSpeedClearsOverrideWithNil() async throws {
        let json = """
        {"id":"show:u1:s1","userId":"u1","showId":"s1","unlistenedEpisodeCount":null,"version":3,"smartSpeed":null}
        """.data(using: .utf8)!
        var capturedBody: Data?
        MockURLProtocol.stubHandler = { request in
            capturedBody = request.capturedBodyData
            return .success(.init(statusCode: 200, data: json, headers: [:]))
        }

        let updated = try await client.updateShowSmartSpeed(showId: "s1", value: nil)

        XCTAssertNil(updated.smartSpeed)
        XCTAssertEqual(updated.version, 3)
        let requestedURL = try XCTUnwrap(MockURLProtocol.requestedURLs.first)
        XCTAssertTrue(requestedURL.absoluteString.hasSuffix("/api/settings/shows/s1/smart-speed"))
        let bodyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(capturedBody)) as? [String: Any])
        XCTAssertNil(bodyJSON["smartSpeed"])
    }
}
