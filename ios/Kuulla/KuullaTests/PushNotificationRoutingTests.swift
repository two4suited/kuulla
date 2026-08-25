import XCTest
@testable import Kuulla

final class PushNotificationRoutingTests: XCTestCase {
    func testRoutesToEpisodeWhenShowIdAndEpisodeIdPresent() {
        let route = PushNotificationRouting.route(from: ["showId": "s1", "episodeId": "e1"])

        XCTAssertEqual(route, .episode(showId: "s1", episodeId: "e1"))
    }

    func testRoutesToShowWhenOnlyShowIdPresent() {
        // Multiple new episodes in one push omit episodeId (ApnsNotificationService only
        // includes it for exactly one new episode) — routes to the show rather than guessing.
        let route = PushNotificationRouting.route(from: ["showId": "s1"])

        XCTAssertEqual(route, .show(id: "s1"))
    }

    func testReturnsNilWhenShowIdMissing() {
        let route = PushNotificationRouting.route(from: ["episodeId": "e1"])

        XCTAssertNil(route)
    }

    func testReturnsNilForUnrelatedPayload() {
        // e.g. the "aps" key every push carries, with no custom data at all.
        let route = PushNotificationRouting.route(from: ["aps": ["alert": ["title": "Show", "body": "New episode"]]])

        XCTAssertNil(route)
    }

    func testIgnoresNonStringShowId() {
        let route = PushNotificationRouting.route(from: ["showId": 42])

        XCTAssertNil(route)
    }
}
