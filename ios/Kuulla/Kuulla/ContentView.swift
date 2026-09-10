import SwiftUI
import UIKit

private enum AppTab: Hashable {
    case library, search, discovery, subscriptions, playlists

#if DEBUG
    init?(argument: String) {
        switch argument.lowercased() {
        case "library": self = .library
        case "search": self = .search
        case "discovery", "discover": self = .discovery
        case "subscriptions": self = .subscriptions
        case "playlists": self = .playlists
        default: return nil
        }
    }
#endif
}

struct ContentView: View {
    @Environment(\.episodeSyncEngine) private var syncEngine
    @State private var authManager = AuthManager.shared
    @State private var errorMessage: String?
    @State private var deepLinkRouter = DeepLinkRouter.shared
    @State private var selectedTab: AppTab = .library
    // Each tab keeps its own independent navigation stack (tapping a show in Search shouldn't
    // affect Library's stack), so a deep link needs to target one tab's path specifically rather
    // than a single shared NavigationPath — Library is the natural "content" home to land a
    // show/episode deep link (#218) regardless of which tab was active when it arrived.
    @State private var tabPaths: [AppTab: NavigationPath] = [:]

    var body: some View {
        content
#if DEBUG
            // Screenshot automation (docs/brand/appstore/): `-KuullaAutoTestSignIn` launches
            // straight into the signed-in app via the dev test-token endpoint, and
            // `-KuullaInitialTab <library|search|discovery|subscriptions|playlists|settings>`
            // selects the opening tab — so store frames can be captured with `xcrun simctl`
            // without driving the UI. `settings` is no longer a tab (#515); it's pushed onto
            // Library's stack instead so the capture path still works.
            .task {
                let args = ProcessInfo.processInfo.arguments
                if args.contains("-KuullaAutoTestSignIn"), !authManager.isSignedIn {
                    do {
                        try await authManager.signInAsTestUser()
                    } catch {
                        // Surface it — a headless capture run that silently stays on the
                        // sign-in screen is hard to diagnose (usually the local API / Aspire
                        // stack isn't up).
                        errorMessage = "Screenshot auto sign-in failed: \(error)"
                    }
                }
                if let i = args.firstIndex(of: "-KuullaInitialTab"), i + 1 < args.count {
                    if args[i + 1].lowercased() == "settings" {
                        selectedTab = .library
                        tabPaths[.library, default: NavigationPath()].append(CatalogRoute.settings)
                    } else if let tab = AppTab(argument: args[i + 1]) {
                        selectedTab = tab
                    }
                }
                if let i = args.firstIndex(of: "-KuullaInitialEpisode"), i + 2 < args.count {
                    deepLinkRouter.pendingRoute = .episode(showId: args[i + 1], episodeId: args[i + 2])
                } else if let i = args.firstIndex(of: "-KuullaInitialShow"), i + 1 < args.count {
                    deepLinkRouter.pendingRoute = .show(id: args[i + 1])
                }
            }
#endif
    }

    @ViewBuilder
    private var content: some View {
        if authManager.isSignedIn {
            TabView(selection: $selectedTab) {
                tab(.library) { LibraryView() }
                    .tabItem { Label("Library", systemImage: "house") }
                    .tag(AppTab.library)
                tab(.search) { SearchView() }
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }
                    .tag(AppTab.search)
                tab(.discovery) { DiscoveryView() }
                    .tabItem { Label("Discover", systemImage: "sparkles") }
                    .tag(AppTab.discovery)
                tab(.subscriptions) { SubscriptionsView() }
                    .tabItem { Label("Subscriptions", systemImage: "square.stack") }
                    .tag(AppTab.subscriptions)
                tab(.playlists) { PlaylistsView() }
                    .tabItem { Label("Playlists", systemImage: "music.note.list") }
                    .tag(AppTab.playlists)
            }
            .onChange(of: deepLinkRouter.pendingRoute) { _, _ in applyPendingDeepLinkIfNeeded() }
            .onAppear { applyPendingDeepLinkIfNeeded() }
        } else {
            NavigationStack {
                signInPrompt
            }
        }
    }

    // Handles both a route that arrives while ContentView is already on screen (.onChange) and
    // one that was set before it appeared — e.g. a cold launch triggered by tapping a
    // notification, where AppDelegate's didReceive can fire before this view's .onChange handler
    // has been registered (#218).
    private func applyPendingDeepLinkIfNeeded() {
        guard let route = deepLinkRouter.pendingRoute else { return }
        selectedTab = .library
        tabPaths[.library, default: NavigationPath()].append(route)
        deepLinkRouter.pendingRoute = nil
    }

    private func tab<Content: View>(_ tabId: AppTab, @ViewBuilder content: () -> Content) -> some View {
        NavigationStack(path: Binding(
            get: { tabPaths[tabId, default: NavigationPath()] },
            set: { tabPaths[tabId] = $0 }
        )) {
            content()
                .navigationDestination(for: CatalogRoute.self) { route in
                    switch route {
                    case .show(let id):
                        ShowDetailView(showId: id)
                    case .episode(let showId, let episodeId):
                        EpisodeDetailView(showId: showId, episodeId: episodeId)
                    case .playlist(let id):
                        PlaylistDetailView(playlistId: id)
                    case .upNext:
                        UpNextView()
                    case .downloads:
                        DownloadsView()
                    case .discoveryCategory(let id):
                        DiscoveryCategoryDetailView(categoryId: id)
                    case .settings:
                        SettingsView()
                    }
                }
        }
    }

    private var signInPrompt: some View {
        VStack(spacing: 16) {
            Text("Kuulla")
                .font(.kuullaTitle(34, relativeTo: .largeTitle))

            Button("Sign in with Google", action: signIn)
                .buttonStyle(.borderedProminent)

#if DEBUG
            Button("Sign in as test user (local only)", action: signInAsTestUser)
                .font(.footnote)
#endif

            if let errorMessage {
                Text(errorMessage)
                    .font(.kuullaBody(13))
                    .foregroundStyle(KuullaColor.danger)
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
                await syncEngine?.syncNow()
                await PushNotificationManager.shared.requestAuthorizationAndRegister()
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
                await syncEngine?.syncNow()
                await PushNotificationManager.shared.requestAuthorizationAndRegister()
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
