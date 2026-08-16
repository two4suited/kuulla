import SwiftUI
import UIKit

struct ContentView: View {
    @State private var authManager = AuthManager.shared
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Kuulla")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                if authManager.isSignedIn {
                    Text(authManager.userEmail ?? "Signed in")
                        .foregroundStyle(.secondary)
                    Button("Sign Out") {
                        authManager.signOut()
                    }
                } else {
                    Button("Sign in with Google", action: signIn)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
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
}

#Preview {
    ContentView()
}
