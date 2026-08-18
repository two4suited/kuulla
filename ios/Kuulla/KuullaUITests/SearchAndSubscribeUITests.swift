import XCTest

// Covers issue #61's search/browse and subscribe flows: find a real show via search, open its
// detail page, and round-trip a subscription through the Subscriptions tab the way a user would
// (Subscriptions has no inline unsubscribe — reaching Unsubscribe means navigating back into the
// show's detail page from its tile).
final class SearchAndSubscribeUITests: KuullaUITestCase {
    func testSearch_OpensShowDetail() {
        signInAsTestUser()

        _ = searchAndOpenFirstShow()

        // The Subscribe/Unsubscribe button only renders once ShowDetailView has finished loading
        // the show, so its presence (in either state) is a signal-agnostic way to confirm
        // navigating into the show detail page actually worked.
        XCTAssertNotNil(waitForSubscribeOrUnsubscribeButton())
    }

    func testSubscribe_ThenUnsubscribe_RoundTripsThroughSubscriptionsTab() {
        signInAsTestUser()

        let showTitle = searchAndOpenFirstShow()

        // A prior failed run may have left the test account subscribed; reset to a known
        // (unsubscribed) state before asserting anything.
        resetSubscriptionIfNeeded()

        let subscribeButton = app.buttons["Subscribe"]
        XCTAssertTrue(subscribeButton.waitForExistence(timeout: 15))
        subscribeButton.tap()
        XCTAssertTrue(app.buttons["Unsubscribe"].waitForExistence(timeout: 15))

        app.tabBars.buttons["Subscriptions"].tap()
        let subscribedTile = app.staticTexts[showTitle].firstMatch
        XCTAssertTrue(subscribedTile.waitForExistence(timeout: 15))

        subscribedTile.tap()
        let unsubscribeButton = app.buttons["Unsubscribe"]
        XCTAssertTrue(unsubscribeButton.waitForExistence(timeout: 15))
        unsubscribeButton.tap()
        XCTAssertTrue(app.buttons["Subscribe"].waitForExistence(timeout: 15))

        // ContentView's per-tab NavigationStack has no bound path, so re-tapping the
        // already-selected "Subscriptions" tab is a no-op rather than the usual
        // tap-again-to-pop-to-root behavior — pop back to the subscriptions list explicitly via
        // its back button instead.
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Popping back to SubscriptionsView's root doesn't re-run its `.task` fetch — only a
        // fresh appearance or `.refreshable` does — so the list would otherwise still show the
        // just-unsubscribed show. Pull to refresh, the same gesture a user would use, before
        // asserting the now-empty state.
        //
        // `.swipeDown()`'s default gesture is too short to reliably cross SwiftUI's
        // `.refreshable` overscroll threshold in the Simulator — it registers as a normal scroll
        // rather than a pull-to-refresh often enough to make this test flaky. A slower,
        // longer-distance press-and-drag from just below the nav bar crosses that threshold
        // consistently.
        let scrollView = app.scrollViews.firstMatch
        let start = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05))
        let end = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)

        XCTAssertTrue(app.staticTexts["You haven't subscribed to any shows yet."].waitForExistence(timeout: 15))
    }

    private func resetSubscriptionIfNeeded() {
        if waitForSubscribeOrUnsubscribeButton()?.label == "Unsubscribe" {
            app.buttons["Unsubscribe"].tap()
            XCTAssertTrue(app.buttons["Subscribe"].waitForExistence(timeout: 15))
        }
    }
}
