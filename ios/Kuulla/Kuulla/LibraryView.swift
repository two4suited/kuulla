import SwiftUI

struct LibraryView: View {
    @State private var subscriptions: [Subscription] = []
    @State private var playlists: [Playlist] = []
    @State private var unplayedCounts: [String: Int] = [:]
    @State private var isLoadingShows = false
    @State private var isLoadingPlaylists = false
    @State private var showsErrorMessage: String?
    @State private var playlistsErrorMessage: String?

    private let subscriptionClient = SubscriptionClient()
    private let playlistClient = PlaylistClient()

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                playlistsSection
                showsSection
            }
            .padding(.vertical)
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(destination: FeedView()) {
                    Image(systemName: "bell")
                }
                .accessibilityLabel("New Episodes")
            }
        }
        .task {
            async let showsTask: Void = loadShows()
            async let playlistsTask: Void = loadPlaylists()
            _ = await (showsTask, playlistsTask)
        }
        .refreshable {
            async let showsTask: Void = loadShows()
            async let playlistsTask: Void = loadPlaylists()
            _ = await (showsTask, playlistsTask)
        }
    }

    private var playlistsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Playlists")
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            if isLoadingPlaylists {
                ProgressView()
                    .padding(.horizontal)
            } else if let playlistsErrorMessage {
                Text(playlistsErrorMessage)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        NavigationLink(value: CatalogRoute.upNext) {
                            ShelfTile(systemImage: "play.fill", title: "Up Next", subtitle: "Your queue", isEnabled: true)
                        }
                        .buttonStyle(.plain)

                        ForEach(playlists) { playlist in
                            NavigationLink(value: CatalogRoute.playlist(id: playlist.id)) {
                                ShelfTile(
                                    systemImage: "music.note.list",
                                    title: playlist.name,
                                    subtitle: "\(playlist.items.count) episode\(playlist.items.count == 1 ? "" : "s")",
                                    isEnabled: true)
                            }
                            .buttonStyle(.plain)
                        }

                        ShelfTile(systemImage: "arrow.down.circle", title: "Downloaded", subtitle: "Coming soon", isEnabled: false)
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    private var showsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Shows")
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            if isLoadingShows {
                ProgressView()
                    .padding(.horizontal)
            } else if let showsErrorMessage {
                Text(showsErrorMessage)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            } else if subscriptions.isEmpty {
                Text("You haven't subscribed to any shows yet.")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            } else {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(subscriptions) { subscription in
                        NavigationLink(value: CatalogRoute.show(id: subscription.showId)) {
                            ShowTile(subscription: subscription, unplayedCount: unplayedCounts[subscription.showId] ?? 0)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func loadShows() async {
        guard !isLoadingShows else { return }
        isLoadingShows = true
        showsErrorMessage = nil

        do {
            let results = try await subscriptionClient.getSubscriptions()
                .sorted { $0.showTitle.localizedCaseInsensitiveCompare($1.showTitle) == .orderedAscending }
            if !Task.isCancelled {
                subscriptions = results
            }
        } catch {
            if !Task.isCancelled {
                showsErrorMessage = "Something went wrong while loading your shows. Please try again."
            }
        }

        // Always clears the flag, even if cancelled — mirrors loadPlaylists()'s defer, just
        // spelled out here because isLoadingShows must go false before the best-effort fetch
        // below, not only at the very end of the method.
        isLoadingShows = false
        guard !Task.isCancelled, showsErrorMessage == nil else { return }

        // Best-effort, run after the grid has already rendered: unplayed badges are supplementary,
        // so a failure here shouldn't hide the already-loaded show grid behind an error.
        if let newEpisodes = try? await subscriptionClient.getNewEpisodes(), !Task.isCancelled {
            unplayedCounts = UnplayedCounts.compute(from: newEpisodes.map(\.showId))
        }
    }

    private func loadPlaylists() async {
        guard !isLoadingPlaylists else { return }
        isLoadingPlaylists = true
        playlistsErrorMessage = nil
        defer { isLoadingPlaylists = false }

        do {
            let results = try await playlistClient.getPlaylists()
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            guard !Task.isCancelled else { return }
            playlists = results
        } catch {
            guard !Task.isCancelled else { return }
            playlistsErrorMessage = "Something went wrong while loading your playlists. Please try again."
        }
    }
}

private struct ShelfTile: View {
    let systemImage: String
    let title: String
    let subtitle: String
    let isEnabled: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.title2)
                .frame(height: 28)
            Text(title)
                .font(.subheadline)
                .lineLimit(1)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: 96)
        .padding(.vertical, 12)
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .foregroundStyle(isEnabled ? .primary : .secondary)
        .opacity(isEnabled ? 1 : 0.6)
    }
}

private struct ShowTile: View {
    let subscription: Subscription
    let unplayedCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                AsyncImage(url: subscription.showArtworkUrl.flatMap(URL.init)) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.secondary.opacity(0.2)
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                if unplayedCount > 0 {
                    let capped = UnplayedCounts.newEpisodesPerShowCap
                    Text(unplayedCount >= capped ? "\(capped)+" : "\(unplayedCount)")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.accentColor, in: Capsule())
                        .padding(4)
                }
            }

            Text(subscription.showTitle)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
    }
}

#Preview {
    NavigationStack {
        LibraryView()
    }
}
