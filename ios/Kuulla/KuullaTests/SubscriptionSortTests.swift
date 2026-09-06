import XCTest
@testable import Kuulla

final class SubscriptionSortTests: XCTestCase {
    private func sub(
        _ id: String, title: String, subscribedAt: Date = Date(timeIntervalSince1970: 0),
        latestEpisodePublishedAt: Date? = nil
    ) -> Subscription {
        Subscription(
            id: "sub-\(id)", userId: "u1", showId: id, showTitle: title, showAuthor: "Author",
            showArtworkUrl: nil, subscribedAt: subscribedAt, latestEpisodePublishedAt: latestEpisodePublishedAt)
    }

    func testTitleOrderIsCaseInsensitiveAscending() {
        let subs = [sub("1", title: "zebra"), sub("2", title: "Apple"), sub("3", title: "mango")]

        let sorted = sortedSubscriptions(subs, by: .title)

        XCTAssertEqual(sorted.map(\.showId), ["2", "3", "1"])
    }

    func testManualWithNoSavedOrderFallsBackToTitle() {
        let subs = [sub("1", title: "zebra"), sub("2", title: "Apple")]

        XCTAssertEqual(sortedSubscriptions(subs, by: .manual).map(\.showId), ["2", "1"])
    }

    func testManualOrdersBySavedArrangement() {
        let subs = [sub("a", title: "Apple"), sub("b", title: "Banana"), sub("c", title: "Cherry")]

        XCTAssertEqual(
            sortedSubscriptions(subs, by: .manual, manualOrder: ["c", "a", "b"]).map(\.showId),
            ["c", "a", "b"])
    }

    func testManualShowsNotInSavedOrderFallToEndByTitle() {
        let subs = [sub("a", title: "zeta"), sub("b", title: "alpha"), sub("c", title: "Cherry")]

        XCTAssertEqual(
            sortedSubscriptions(subs, by: .manual, manualOrder: ["c"]).map(\.showId),
            ["c", "b", "a"])
    }

    func testManualIgnoresUnsubscribedIdsInSavedOrder() {
        let subs = [sub("a", title: "Apple"), sub("b", title: "Banana")]

        XCTAssertEqual(
            sortedSubscriptions(subs, by: .manual, manualOrder: ["ghost", "b", "a"]).map(\.showId),
            ["b", "a"])
    }

    func testRecentlyAddedOrdersNewestFirst() {
        let subs = [
            sub("old", title: "A", subscribedAt: Date(timeIntervalSince1970: 100)),
            sub("new", title: "B", subscribedAt: Date(timeIntervalSince1970: 300)),
            sub("mid", title: "C", subscribedAt: Date(timeIntervalSince1970: 200)),
        ]

        XCTAssertEqual(sortedSubscriptions(subs, by: .recentlyAdded).map(\.showId), ["new", "mid", "old"])
    }

    func testLatestEpisodeOrdersNewestFirstAndSortsUnknownDatesLast() {
        let subs = [
            sub("stale", title: "A", latestEpisodePublishedAt: Date(timeIntervalSince1970: 100)),
            sub("fresh", title: "B", latestEpisodePublishedAt: Date(timeIntervalSince1970: 500)),
            sub("unknown", title: "C", latestEpisodePublishedAt: nil),
        ]

        XCTAssertEqual(sortedSubscriptions(subs, by: .latestEpisode).map(\.showId), ["fresh", "stale", "unknown"])
    }

    func testLatestEpisodeTieBreaksOnTitle() {
        let sameDate = Date(timeIntervalSince1970: 200)
        let subs = [
            sub("1", title: "zebra", latestEpisodePublishedAt: sameDate),
            sub("2", title: "apple", latestEpisodePublishedAt: sameDate),
        ]

        XCTAssertEqual(sortedSubscriptions(subs, by: .latestEpisode).map(\.showId), ["2", "1"])
    }

    func testLatestEpisodeSinksCaughtUpShowsBelowActiveOnes() {
        let subs = [
            sub("caught-up-fresh", title: "A", latestEpisodePublishedAt: Date(timeIntervalSince1970: 900)),
            sub("active-stale", title: "B", latestEpisodePublishedAt: Date(timeIntervalSince1970: 100)),
        ]

        let sorted = sortedSubscriptions(subs, by: .latestEpisode, activeShowIds: ["active-stale"])

        XCTAssertEqual(sorted.map(\.showId), ["active-stale", "caught-up-fresh"])
    }

    func testLatestEpisodeNilActiveShowIdsLeavesOrderUnchanged() {
        let subs = [
            sub("stale", title: "A", latestEpisodePublishedAt: Date(timeIntervalSince1970: 100)),
            sub("fresh", title: "B", latestEpisodePublishedAt: Date(timeIntervalSince1970: 500)),
        ]

        XCTAssertEqual(
            sortedSubscriptions(subs, by: .latestEpisode, activeShowIds: nil).map(\.showId),
            ["fresh", "stale"])
    }

    func testHideCaughtUpRemovesShowsNotInActiveSet() {
        let subs = [sub("a", title: "Apple"), sub("b", title: "Banana"), sub("c", title: "Cherry")]

        let sorted = sortedSubscriptions(subs, by: .title, activeShowIds: ["b"], hideCaughtUp: true)

        XCTAssertEqual(sorted.map(\.showId), ["b"])
    }

    func testHideCaughtUpWithNilActiveShowIdsKeepsEveryShow() {
        let subs = [sub("a", title: "Apple"), sub("b", title: "Banana")]

        let sorted = sortedSubscriptions(subs, by: .title, activeShowIds: nil, hideCaughtUp: true)

        XCTAssertEqual(sorted.map(\.showId), ["a", "b"])
    }

    func testHideCaughtUpIgnoredInManualMode() {
        let subs = [sub("a", title: "Apple"), sub("b", title: "Banana"), sub("c", title: "Cherry")]

        let sorted = sortedSubscriptions(
            subs, by: .manual, manualOrder: ["c", "a", "b"], activeShowIds: ["b"], hideCaughtUp: true)

        XCTAssertEqual(sorted.map(\.showId), ["c", "a", "b"])
    }
}
