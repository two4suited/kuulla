import SwiftUI
import UIKit

struct ContentView: View {
    @State private var authManager = AuthManager.shared
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if authManager.isSignedIn {
                    SearchView()
                } else {
                    signInPrompt
                }
            }
            .navigationDestination(for: CatalogRoute.self) { route in
                switch route {
                case .show(let id):
                    ShowDetailView(showId: id)
                case .episode(let showId, let episodeId):
                    EpisodeDetailView(showId: showId, episodeId: episodeId)
                }
            }
            .toolbar {
                if authManager.isSignedIn {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Sign Out") {
                            authManager.signOut()
                        }
                    }
                }
            }
        }
    }

    private var signInPrompt: some View {
        VStack(spacing: 16) {
            Text("Kuulla")
                .font(.largeTitle)
                .fontWeight(.bold)

            Button("Sign in with Google", action: signIn)

#if DEBUG
            Button("Sign in as test user (local only)", action: signInAsTestUser)
                .font(.footnote)
#endif

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func signIn() {
        guard let rootViewController = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first?.windows.first(where: \.isKeyWindow)?.rootViewController
        else { return }

        Task {
            do {
                try await authManager.signIn(presenting: rootViewController)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

#if DEBUG
    private func signInAsTestUser() {
        Task {
            do {
                try await authManager.signInAsTestUser()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
#endif
}

#Preview {
    ContentView()
}
