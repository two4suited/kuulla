import GoogleSignIn
import Observation
import UIKit

@Observable
final class AuthManager {
    static let shared = AuthManager()

    private(set) var userEmail: String?
    private(set) var isSignedIn = false

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
        apply(nil)
    }

    // GIDSignIn caches tokens in the keychain, but ID tokens expire (~1 hour), so every
    // outbound API call refreshes first rather than reusing a token that may have expired.
    func validIdToken() async throws -> String {
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
}

enum AuthError: Error {
    case notSignedIn
    case noIdToken
}
