import XCTest

// These tests drive the real app against a real, already-running API (issue #61) — there's no
// AppHost equivalent XCUITest can boot itself the way Kuulla.Web.E2E's WebAppFixture does, so a
// KUULLA_API_BASE_URL pointing at a reachable API (e.g. `aspire describe api`, or the
// launchSettings default) has to be supplied by whoever runs them. Skip rather than fail when
// it's absent, since that's the normal case in CI until #51 resolves the dynamic-port problem.
class KuullaUITestCase: XCTestCase {
    private(set) var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false

        guard let apiBaseURL = ProcessInfo.processInfo.environment["KUULLA_API_BASE_URL"], !apiBaseURL.isEmpty else {
            throw XCTSkip("Set KUULLA_API_BASE_URL to a reachable Kuulla API to run KuullaUITests.")
        }

        app = XCUIApplication()
        app.launchEnvironment["KUULLA_API_BASE_URL"] = apiBaseURL
        app.launch()
    }

    // Mirrors WebTestHelpers.SignInAsTestUserAsync (tests/Kuulla.Web.E2E/WebTestHelpers.cs):
    // taps the same DEBUG-only "sign in as test user" affordance ContentView renders, rather than
    // poking auth state directly, so the test also exercises the real sign-in path.
    func signInAsTestUser() {
        let signInButton = app.buttons["Sign in as test user (local only)"]
        XCTAssertTrue(signInButton.waitForExistence(timeout: 10))
        signInButton.tap()

        XCTAssertTrue(app.tabBars.buttons["Search"].waitForExistence(timeout: 10))
    }

    // Searches against the real iTunes podcast directory (ShowService.SearchAsync has no
    // dev/test double) for a well-established, stable show — same tradeoff and the same search
    // term as Kuulla.Web.E2E's BrowseAndPlaybackTests: real network flakiness in exchange for
    // proving search actually round-trips through the real directory.
    static let searchTerm = "Radiolab"

    // Returns the opened show's title, read from ShowDetailView's navigation bar rather than
    // from the tapped search result row: ShowRow's accessibility label combines the show's title
    // *and* author into one string (SwiftUI merges a row's child Text elements), while
    // SubscriptionsView's tile only renders the bare title — so comparing the row's label against
    // a tile's label would never match.
    @discardableResult
    func searchAndOpenFirstShow() -> String {
        app.tabBars.buttons["Search"].tap()

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        searchField.tap()
        searchField.typeText(Self.searchTerm)

        // Queried as a generic descendant rather than `.buttons`/`.cells` specifically, since
        // which concrete accessibility element type a List row's NavigationLink surfaces as
        // isn't something to hardcode here.
        let firstResult = app.descendants(matching: .any)["show-row"].firstMatch
        XCTAssertTrue(firstResult.waitForExistence(timeout: 20))
        firstResult.tap()

        let navigationTitle = app.navigationBars.staticTexts.firstMatch
        XCTAssertTrue(navigationTitle.waitForExistence(timeout: 20))
        return navigationTitle.label
    }

    // ShowDetailView renders exactly one of Subscribe/Unsubscribe once it finishes loading the
    // show, and never both — waiting on either is the signal-agnostic way to confirm the page
    // loaded, regardless of which subscription state it starts in. `waitForExistence` can't be
    // used directly here since it only waits on one specific element at a time.
    @discardableResult
    func waitForSubscribeOrUnsubscribeButton(timeout: TimeInterval = 15) -> XCUIElement? {
        let subscribeButton = app.buttons["Subscribe"]
        let unsubscribeButton = app.buttons["Unsubscribe"]

        let deadline = Date().addingTimeInterval(timeout)
        while !subscribeButton.exists && !unsubscribeButton.exists && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        if unsubscribeButton.exists { return unsubscribeButton }
        if subscribeButton.exists { return subscribeButton }
        return nil
    }
}
