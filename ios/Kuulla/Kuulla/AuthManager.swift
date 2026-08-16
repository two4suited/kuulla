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

    private init() {}

    func restorePreviousSignIn() async {
        guard GIDSignIn.sharedInstance.hasPreviousSignIn() else { return }
        let user = try? await GIDSignIn.sharedInstance.restorePreviousSignIn()
        apply(user)
    }

    @MainActor
    func signIn(presenting viewController: UIViewController) async throws {
        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: viewController)
        apply(result.user)
    }

    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        localTestIdToken = nil
        apply(nil)
    }

    // GIDSignIn caches tokens in the keychain, but ID tokens expire (~1 hour), so every
    // outbound API call refreshes first rather than reusing a token that may have expired.
    func validIdToken() async throws -> String {
        if let localTestIdToken {
            return localTestIdToken
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

    func signInAsTestUser(apiBaseURL: URL = AuthManager.localTestApiBaseURL) async throws {
        var request = URLRequest(url: apiBaseURL.appendingPathComponent("dev/test-token"))
        request.httpMethod = "POST"

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw AuthError.noIdToken
        }

        let payload = try JSONDecoder().decode(LocalTestTokenResponse.self, from: data)
        localTestIdToken = payload.token
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
}
