import SwiftUI

// The Overcast-style "Up Next" queue is just a regular playlist the app resolves (or creates) by
// this well-known name, rather than a separate backend concept — mirrors
// src/Kuulla.Web/Components/Pages/UpNext.razor, since there's no per-user "default playlist"
// notion in the API and the Playlist/PlaylistItem domain from milestone #14 already covers
// everything a manually-managed reorderable queue needs.
struct UpNextView: View {
    static let upNextPlaylistName = "Up Next"

    @State private var playlistId: String?
    @State private var isResolving = true
    @State private var isResolveInFlight = false
    @State private var resolveError: String?

    private let playlistClient = PlaylistClient()

    var body: some View {
        Group {
            if let playlistId {
                PlaylistDetailView(playlistId: playlistId)
            } else if isResolving {
                ProgressView()
                    .navigationTitle("Up Next")
            } else if let resolveError {
                VStack(spacing: 12) {
                    Text(resolveError)
                        .foregroundStyle(.red)
                    Button("Retry") {
                        Task { await resolve() }
                    }
                }
                .navigationTitle("Up Next")
            }
        }
        .task {
            await resolve()
        }
    }

    private func resolve() async {
        guard playlistId == nil, !isResolveInFlight else { return }
        isResolveInFlight = true
        isResolving = true
        resolveError = nil
        defer {
            isResolving = false
            isResolveInFlight = false
        }

        do {
            let playlists = try await playlistClient.getPlaylists()
            guard !Task.isCancelled else { return }

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
                guard !Task.isCancelled else { return }
                playlistId = try await playlistClient.createPlaylist(name: Self.upNextPlaylistName).id
            }
        } catch {
            if !Task.isCancelled {
                resolveError = "Something went wrong while loading your queue. Please try again."
            }
        }
    }
}

#Preview {
    NavigationStack {
        UpNextView()
    }
}
