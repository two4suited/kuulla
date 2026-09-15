import SwiftUI

// Ports Kuulla.Web's AddToPlaylistButton.razor UX to a sheet: existing playlists to tap-add into,
// plus an inline "new playlist" create-then-add flow.
struct AddToPlaylistSheet: View {
    let episodeId: String
    let showId: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.playlistSyncEngine) private var playlistSyncEngine
    @State private var playlists: [Playlist] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var newPlaylistName = ""
    @State private var isBusy = false
    @State private var actionError: String?
    @State private var addedPlaylistIds: Set<String> = []

    private let playlistClient = PlaylistClient()

    var body: some View {
        NavigationStack {
            List {
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if let loadError {
                    Text(loadError)
                        .foregroundStyle(.red)
                } else {
                    ForEach(playlists) { playlist in
                        Button {
                            Task { await addToExisting(playlist) }
                        } label: {
                            HStack {
                                if let icon = playlist.icon, !icon.isEmpty {
                                    Text(icon)
                                        .foregroundStyle(Color(playlistAccentHex: playlist.accentColor) ?? .primary)
                                }
                                Text(playlist.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if addedPlaylistIds.contains(playlist.id) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(isBusy)
                    }
                }

                Section("New Playlist") {
                    HStack {
                        TextField("Playlist name", text: $newPlaylistName)
                        Button("Add") {
                            Task { await addToNew() }
                        }
                        .disabled(isBusy || newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                if let actionError {
                    Text(actionError)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await loadPlaylists()
            }
        }
    }

    private func loadPlaylists() async {
        isLoading = true
        loadError = nil
        do {
            playlists = try await playlistClient.getPlaylists()
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            loadError = "Couldn't load your playlists."
        }
        isLoading = false
    }

    private func addToExisting(_ playlist: Playlist) async {
        isBusy = true
        actionError = nil
        do {
            try await playlistClient.addItem(playlistId: playlist.id, episodeId: episodeId, showId: showId)
            addedPlaylistIds.insert(playlist.id)
            // The add went straight to the server via REST, bypassing the playlist SyncEngine —
            // pull it back down now so the local store (and anything reading through it, like
            // PlaylistsView/LibraryView) doesn't wait for the next unrelated sync (#745).
            await playlistSyncEngine?.syncNow()
        } catch {
            actionError = "Something went wrong. Please try again."
        }
        isBusy = false
    }

    private func addToNew() async {
        let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        isBusy = true
        actionError = nil
        do {
            let created = try await playlistClient.createPlaylist(name: name)
            try await playlistClient.addItem(playlistId: created.id, episodeId: episodeId, showId: showId)
            playlists.append(created)
            playlists.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            addedPlaylistIds.insert(created.id)
            newPlaylistName = ""
            // Same reasoning as addToExisting: pull the new playlist + item back into the local
            // store immediately rather than waiting for the next unrelated sync (#745).
            await playlistSyncEngine?.syncNow()
        } catch {
            actionError = "Something went wrong. Please try again."
        }
        isBusy = false
    }
}

#Preview {
    AddToPlaylistSheet(episodeId: "preview-episode", showId: "preview-show")
}
