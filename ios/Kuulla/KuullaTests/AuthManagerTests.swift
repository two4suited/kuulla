import XCTest
@testable import Kuulla

final class AuthManagerTests: XCTestCase {
    func testValidIdTokenThrowsWhenNotSignedIn() async {
        do {
            _ = try await AuthManager.shared.validIdToken()
            XCTFail("expected AuthError.notSignedIn")
        } catch AuthError.notSignedIn {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
