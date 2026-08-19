import SwiftUI

struct PlaylistDetailView: View {
    let playlistId: String

    @State private var playlist: PlaylistDetail?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var mutationError: String?

    private let playlistClient = PlaylistClient()

    var body: some View {
        List {
            if let playlist {
                if playlist.items.isEmpty {
                    Text("This playlist is empty. Add episodes to it from a show or episode page.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(playlist.items) { item in
                        NavigationLink(value: CatalogRoute.episode(showId: item.showId, episodeId: item.episodeId)) {
                            PlaylistItemRow(item: item)
                        }
                    }
                    .onDelete { offsets in
                        Task { await removeItems(at: offsets) }
                    }
                    .onMove { source, destination in
                        Task { await moveItem(from: source, to: destination) }
                    }
                }
            } else if let loadError {
                Text(loadError)
                    .foregroundStyle(.red)
            } else if !isLoading {
                Text("Playlist not found.")
                    .foregroundStyle(.secondary)
            }

            if let mutationError {
                Text(mutationError)
                    .foregroundStyle(.red)
            }
        }
        .navigationTitle(playlist?.name ?? "Playlist")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let playlist, playlist.items.count > 1 {
                    EditButton()
                }
            }
            ToolbarItem(placement: .bottomBar) {
                if let firstItem = playlist?.items.first {
                    NavigationLink(value: CatalogRoute.episode(showId: firstItem.showId, episodeId: firstItem.episodeId)) {
                        Label("Play", systemImage: "play.fill")
                    }
                }
            }
        }
        .overlay {
            if isLoading {
                ProgressView()
            }
        }
        .task(id: playlistId) {
            await load()
        }
    }

    private func load() async {
        playlist = nil
        loadError = nil
        isLoading = true
        do {
            playlist = try await playlistClient.getPlaylistDetail(id: playlistId)
        } catch {
            if !Task.isCancelled {
                loadError = "Something went wrong while loading this playlist. Please try again."
            }
        }
        isLoading = false
    }

    private func removeItems(at offsets: IndexSet) async {
        guard let items = playlist?.items else { return }
        mutationError = nil

        let removedItems = offsets.map { items[$0] }
        var updated = items
        updated.remove(atOffsets: offsets)
        playlist?.items = updated

        // One item at a time (not all-or-nothing) so a failure partway through a multi-select
        // delete only restores the items that actually failed — restoring the whole original
        // snapshot would re-add items whose DELETE already succeeded, leaving the UI showing
        // something the server has already forgotten.
        for item in removedItems {
            do {
                try await playlistClient.removeItem(playlistId: playlistId, episodeId: item.episodeId)
            } catch {
                playlist?.items.append(item)
                mutationError = "Something went wrong while removing this episode. Please try again."
            }
        }
    }

    private func moveItem(from source: IndexSet, to destination: Int) async {
        guard let items = playlist?.items, let sourceIndex = source.first else { return }
        mutationError = nil

        var updated = items
        updated.move(fromOffsets: source, toOffset: destination)
        playlist?.items = updated

        let movedEpisodeId = items[sourceIndex].episodeId
        guard let movedIndex = updated.firstIndex(where: { $0.episodeId == movedEpisodeId }) else { return }
        let beforeEpisodeId = movedIndex > 0 ? updated[movedIndex - 1].episodeId : nil
        let afterEpisodeId = movedIndex < updated.count - 1 ? updated[movedIndex + 1].episodeId : nil

        do {
            try await playlistClient.reorderItem(
                playlistId: playlistId, episodeId: movedEpisodeId,
                beforeEpisodeId: beforeEpisodeId, afterEpisodeId: afterEpisodeId)
        } catch {
            // Re-fetch rather than reverting to the pre-drag snapshot: a stale/racing neighbor id
            // (the same failure mode PlaylistService.ReorderItemAsync rejects server-side) means
            // our local guess about the "before" state may itself be wrong.
            await load()
            mutationError = "Something went wrong while reordering. Please try again."
        }
    }
}

private struct PlaylistItemRow: View {
    let item: PlaylistItemDetail

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: item.artworkUrl.flatMap(URL.init)) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.secondary.opacity(0.2)
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Text(item.title ?? "(episode unavailable)")
                .lineLimit(2)
        }
    }
}

#Preview {
    NavigationStack {
        PlaylistDetailView(playlistId: "preview-playlist")
    }
}
