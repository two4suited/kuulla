import Foundation
import GoogleSignIn
import Observation
import UIKit

@Observable
final class AuthManager {
    static let shared = AuthManager()

    private(set) var userEmail: String?
    private(set) var isSignedIn = false

    private var localTestIdToken: String?

    // Bumped by every deliberate auth action (sign in, test sign in, sign out) so
    // restorePreviousSignIn() — a launch-time restore racing a real network round-trip to Google
    // — can tell whether the user has since acted on their own and, if so, discard its own
    // stale result instead of clobbering whatever the user did (including a sign-out that
    // happened while the restore was still in flight).
    private var authActionEpoch = 0

    private init() {}

    @MainActor
    func restorePreviousSignIn() async {
        guard GIDSignIn.sharedInstance.hasPreviousSignIn() else { return }
        let epochAtStart = authActionEpoch
        let user = try? await GIDSignIn.sharedInstance.restorePreviousSignIn()
        guard authActionEpoch == epochAtStart else { return }
        apply(user)
    }

    @MainActor
    func signIn(presenting viewController: UIViewController) async throws {
        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: viewController)
        authActionEpoch += 1
        apply(result.user)
    }

    @MainActor
    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        localTestIdToken = nil
        authActionEpoch += 1
        apply(nil)
    }

    // GIDSignIn caches tokens in the keychain, but ID tokens expire (~1 hour), so every
    // outbound API call refreshes first rather than reusing a token that may have expired.
    func validIdToken() async throws -> String {
        if let localTestIdToken {
            return localTestIdToken
        }
        // restorePreviousSignIn() normally runs from ContentView's cold-launch .task, which
        // requires the app's own WindowGroup scene to have appeared at least once. CarPlay can
        // launch the app on its own scene role (e.g. the car starting before the phone is ever
        // unlocked/opened) without that scene ever appearing, leaving GIDSignIn.currentUser nil
        // for an actually-signed-in user — surfacing as "Couldn't load your subscriptions" on
        // CarPlay's browse screen (#631). Restoring lazily here covers that path too.
        if GIDSignIn.sharedInstance.currentUser == nil {
            await restorePreviousSignIn()
        }
        guard let user = GIDSignIn.sharedInstance.currentUser else {
            throw AuthError.notSignedIn
        }
        let refreshed = try await user.refreshTokensIfNeeded()
        guard let idToken = refreshed.idToken?.tokenString else {
            throw AuthError.noIdToken
        }
        return idToken
    }

    private func apply(_ user: GIDGoogleUser?) {
        userEmail = user?.profile?.email
        isSignedIn = user != nil
    }

#if DEBUG
    // Local-testing-only (issue #48): fetches a token from the API's dev-only /dev/test-token
    // endpoint instead of running the real Google sign-in flow, so the simulator can reach
    // authenticated screens without Google credentials configured. Compiled out of release
    // builds, and the endpoint it calls only exists when the API itself is running in
    // Development.
    //
    // Aspire assigns the API a random local port on every `aspire start`/`aspire run`, so there
    // is no fixed URL to hardcode. Check the port with `aspire describe api` (or the dashboard)
    // and set it as KUULLA_API_BASE_URL in the Xcode scheme's environment variables; this falls
    // back to the port in Kuulla.Api's launchSettings.json http profile, which is only correct
    // when the API is run directly (`dotnet run`) rather than through Aspire.
    static var localTestApiBaseURL: URL {
        if let override = ProcessInfo.processInfo.environment["KUULLA_API_BASE_URL"],
           let url = URL(string: override) {
            return url
        }
        return URL(string: "http://localhost:5245")!
    }

    @MainActor
    func signInAsTestUser(apiBaseURL: URL = AuthManager.localTestApiBaseURL) async throws {
        var request = URLRequest(url: apiBaseURL.appendingPathComponent("dev/test-token"))
        request.httpMethod = "POST"

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            throw AuthError.localTestSignInFailed(statusCode: statusCode)
        }

        let payload = try JSONDecoder().decode(LocalTestTokenResponse.self, from: data)
        localTestIdToken = payload.token
        authActionEpoch += 1
        userEmail = "test@local.kuulla.dev"
        isSignedIn = true
    }

    private struct LocalTestTokenResponse: Decodable {
        let token: String
    }
#endif
}

enum AuthError: Error {
    case notSignedIn
    case noIdToken
    case localTestSignInFailed(statusCode: Int?)
}
