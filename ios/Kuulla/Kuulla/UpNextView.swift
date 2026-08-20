import SwiftUI

// The Overcast-style "Up Next" queue is just a regular playlist the app resolves (or creates) by
// this well-known name, rather than a separate backend concept — mirrors
// src/Kuulla.Web/Components/Pages/UpNext.razor, since there's no per-user "default playlist"
// notion in the API and the Playlist/PlaylistItem domain from milestone #14 already covers
// everything a manually-managed reorderable queue needs.
struct UpNextView: View {
    static let upNextPlaylistName = "Up Next"

    @State private var playlistId: String?
    @State private var isResolving = false
    @State private var resolveError: String?

    private let playlistClient = PlaylistClient()

    var body: some View {
        Group {
            if let playlistId {
                VStack(spacing: 0) {
                    autoAddBanner
                    PlaylistDetailView(playlistId: playlistId)
                }
            } else if isResolving {
                ProgressView()
                    .navigationTitle("Up Next")
            } else if let resolveError {
                Text(resolveError)
                    .foregroundStyle(.red)
                    .navigationTitle("Up Next")
            }
        }
        .task {
            await resolve()
        }
    }

    private var autoAddBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("Auto-add")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.2), in: Capsule())

            Text("""
                Automatically queueing new episodes from your subscriptions isn't available yet — \
                add episodes to your queue manually from a show or episode page for now.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private func resolve() async {
        guard playlistId == nil else { return }
        isResolving = true
        resolveError = nil

        do {
            let playlists = try await playlistClient.getPlaylists()
            // Oldest-by-createdAt so selection is deterministic even if a race (e.g. two sessions
            // both seeing no existing playlist) ends up creating more than one — the API has no
            // per-user unique-name guarantee, so this always converges on the same (oldest) one
            // rather than flapping between duplicates on every load.
            if let existing = playlists
                .filter({ $0.name == Self.upNextPlaylistName })
                .min(by: { $0.createdAt < $1.createdAt })
            {
                playlistId = existing.id
            } else {
                playlistId = try await playlistClient.createPlaylist(name: Self.upNextPlaylistName).id
            }
        } catch {
            if !Task.isCancelled {
                resolveError = "Something went wrong while loading your queue. Please try again."
            }
        }

        isResolving = false
    }
}

#Preview {
    NavigationStack {
        UpNextView()
    }
}
