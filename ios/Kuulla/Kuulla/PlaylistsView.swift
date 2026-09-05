import SwiftUI

struct PlaylistsView: View {
    @State private var playlists: [Playlist] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var deleteError: String?
    @State private var isShowingCreateSheet = false

    private let playlistClient = PlaylistClient()

    var body: some View {
        List {
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            } else if isLoading && playlists.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if playlists.isEmpty {
                Text("You haven't created any playlists yet.")
                    .foregroundStyle(.secondary)
            } else {
                if let deleteError {
                    Text(deleteError)
                        .foregroundStyle(.red)
                }

                ForEach(playlists) { playlist in
                    NavigationLink(value: CatalogRoute.playlist(id: playlist.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(playlist.name)
                            Text("\(playlist.items.count) episode\(playlist.items.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    Task { await deletePlaylists(at: offsets) }
                }
            }
        }
        .navigationTitle("Playlists")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isShowingCreateSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New playlist")
            }
        }
        .sheet(isPresented: $isShowingCreateSheet) {
            NewPlaylistSheet(onCreate: createPlaylist)
        }
        .task {
            await loadPlaylists()
        }
        .refreshable {
            await loadPlaylists()
        }
    }

    private func loadPlaylists() async {
        guard !isLoading else { return }

        isLoading = true
        errorMessage = nil
        deleteError = nil
        defer { isLoading = false }

        do {
            let results = try await playlistClient.getPlaylists()
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            guard !Task.isCancelled else { return }
            playlists = results
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = "Something went wrong while loading your playlists. Please try again."
        }
    }

    private func createPlaylist(name: String) async throws {
        let created = try await playlistClient.createPlaylist(name: name)
        playlists.append(created)
        playlists.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func deletePlaylists(at offsets: IndexSet) async {
        deleteError = nil

        let deleted = offsets.map { playlists[$0] }
        playlists.remove(atOffsets: offsets)

        // One at a time (not all-or-nothing) so a failure partway through only restores the
        // playlists that actually failed — mirrors PlaylistDetailView.removeItems(at:).
        for playlist in deleted {
            do {
                try await playlistClient.deletePlaylist(id: playlist.id)
            } catch {
                playlists.append(playlist)
                playlists.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                deleteError = "Something went wrong while deleting this playlist. Please try again."
            }
        }
    }
}

private struct NewPlaylistSheet: View {
    let onCreate: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Playlist name", text: $name)
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("New Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isCreating {
                        ProgressView()
                    } else {
                        Button("Create") {
                            Task { await create() }
                        }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }

    private func create() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isCreating = true
        errorMessage = nil
        do {
            try await onCreate(trimmed)
            dismiss()
        } catch {
            errorMessage = "Something went wrong while creating this playlist. Please try again."
        }
        isCreating = false
    }
}

#Preview {
    NavigationStack {
        PlaylistsView()
    }
}
