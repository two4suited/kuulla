import SwiftData
import SwiftUI

struct PlaylistsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.playlistSyncEngine) private var playlistSyncEngine

    @State private var playlists: [PlaylistSummary] = []
    // Stays false only until the first (synchronous, instant) read of the local store lands, so a
    // cold launch shows a spinner rather than flashing the "no playlists" empty state first.
    @State private var hasLoadedLocal = false
    @State private var isSyncing = false
    @State private var deleteError: String?
    @State private var isShowingCreateSheet = false

    private let playlistClient = PlaylistClient()

    var body: some View {
        List {
            if !hasLoadedLocal {
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
                        HStack(spacing: 10) {
                            if let icon = playlist.icon, !icon.isEmpty {
                                Text(icon)
                                    .font(.title3)
                                    .foregroundStyle(Color(playlistAccentHex: playlist.accentColor) ?? .primary)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlist.name)
                                Text("\(playlist.itemCount) episode\(playlist.itemCount == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
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
                .presentationDetents([.medium, .large])
        }
        .task {
            await refresh()
        }
        .refreshable {
            await refresh()
        }
        .onAppear {
            // Re-sync each time the tab is revisited — the shared TabView keeps this view alive,
            // so `.task` only runs once. A read-only re-read here isn't enough: item adds/removes
            // on PlaylistDetailView go straight to the server (PlaylistClient), not through this
            // view's ModelContext, so the local PlaylistRecord.items (and this list's displayed
            // episode count) stays stale until a sync pulls the server's current state back in.
            Task { await reconcileWithServer() }
        }
    }

    // Paint from the local sync store immediately, then let the playlist SyncEngine refresh from
    // the server behind the already-visible list (#511). The engine owns the network round trip
    // and persists what it pulls into SwiftData; this view only ever reads that store.
    private func refresh() async {
        deleteError = nil
        readLocalPlaylists()
        await reconcileWithServer()
    }

    // Sync, then re-read — with no pre-sync `readLocalPlaylists()`. The mutation helpers use this
    // instead of `refresh()`: right after a create the server's row isn't in the local store yet,
    // and right after a delete the local row is still there (the tombstone arrives with the next
    // pull), so re-reading before the sync completes would drop the just-created row / resurrect
    // the just-deleted one until the round trip finishes.
    private func reconcileWithServer() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        await playlistSyncEngine?.syncNow()
        guard !Task.isCancelled else { return }
        readLocalPlaylists()
    }

    private func readLocalPlaylists() {
        playlists = PlaylistSummary.local(in: modelContext)
        hasLoadedLocal = true
    }

    private func deleteLocalRecord(id: String) {
        let descriptor = FetchDescriptor<PlaylistRecord>(predicate: #Predicate { $0.id == id })
        guard let record = try? modelContext.fetch(descriptor).first else { return }
        modelContext.delete(record)
        try? modelContext.save()
    }

    private func createPlaylist(
        name: String, icon: String?, accentColor: String?, dynamicConfig: DynamicPlaylistConfig?
    ) async throws {
        let created: Playlist
        if let dynamicConfig {
            created = try await playlistClient.createDynamicPlaylist(
                name: name, config: dynamicConfig, icon: icon, accentColor: accentColor)
        } else {
            created = try await playlistClient.createPlaylist(name: name, icon: icon, accentColor: accentColor)
        }
        // Optimistic — show it now; the sync then pulls the server's authoritative row into the
        // local store so it persists across launches and reaches every other PlaylistRecord reader.
        playlists = (playlists + [PlaylistSummary(playlist: created)])
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        Task { await reconcileWithServer() }
    }

    private func deletePlaylists(at offsets: IndexSet) async {
        deleteError = nil

        let deleted = offsets.map { playlists[$0] }
        playlists.remove(atOffsets: offsets)

        // One at a time (not all-or-nothing) so a failure partway through only restores the
        // playlists that actually failed — mirrors PlaylistDetailView.removeItems(at:).
        var anyDeleted = false
        for playlist in deleted {
            do {
                try await playlistClient.deletePlaylist(id: playlist.id)
                // Drop the local row through this view's own ModelContext too (mirrors
                // DownloadCleanup.delete): the sync tombstone that removes it in the engine's
                // context arrives on the next pull, and until then a re-read here would show the
                // deleted playlist again.
                deleteLocalRecord(id: playlist.id)
                anyDeleted = true
            } catch {
                playlists = (playlists + [playlist])
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                deleteError = "Something went wrong while deleting this playlist. Please try again."
            }
        }

        // Sync so the local store drops the now-tombstoned rows too, keeping this list and every
        // other PlaylistRecord reader consistent without waiting for the next natural trigger.
        if anyDeleted {
            await reconcileWithServer()
        }
    }
}

private struct NewPlaylistSheet: View {
    let onCreate: (String, String?, String?, DynamicPlaylistConfig?) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var icon: String?
    @State private var accentColor: String?
    @State private var isDynamic = false
    @State private var maxEpisodes = 20
    @State private var priorityList: [String] = []
    @State private var pendingShowId = ""
    @State private var subscriptions: [Subscription] = []
    @State private var isLoadingSubscriptions = false
    @State private var subscriptionsError: String?
    @State private var isCreating = false
    @State private var errorMessage: String?

    private let subscriptionClient = SubscriptionClient()

    private var availableSubscriptions: [Subscription] {
        subscriptions
            .filter { !priorityList.contains($0.showId) }
            .sorted { $0.showTitle.localizedCaseInsensitiveCompare($1.showTitle) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Playlist name", text: $name)

                Section {
                    Picker("Type", selection: $isDynamic) {
                        Text("Manual").tag(false)
                        Text("Dynamic").tag(true)
                    }
                    .pickerStyle(.segmented)
                }

                if isDynamic {
                    Section("Max episodes") {
                        Stepper(value: $maxEpisodes, in: 1...100) {
                            Text("\(maxEpisodes)")
                        }
                    }

                    Section("Add a podcast") {
                        Picker("Podcast", selection: $pendingShowId) {
                            Text("Choose a podcast")
                                .tag("")
                            ForEach(availableSubscriptions, id: \.showId) { subscription in
                                Text(subscription.showTitle)
                                    .tag(subscription.showId)
                            }
                        }

                        Button("Add") {
                            guard !pendingShowId.isEmpty else { return }
                            if !priorityList.contains(pendingShowId) {
                                priorityList.append(pendingShowId)
                                pendingShowId = ""
                            }
                        }
                        .disabled(pendingShowId.isEmpty)
                    }

                    if priorityList.isEmpty {
                        Section {
                            Text("Choose at least one podcast. Episodes are pulled from the highest-priority podcast first.")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Section("Priority order") {
                            ForEach(priorityList, id: \.self) { showId in
                                HStack {
                                    Text(showTitle(for: showId))
                                    Spacer()
                                    Button(role: .destructive) {
                                        priorityList.removeAll { $0 == showId }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .onMove { source, destination in
                                priorityList.move(fromOffsets: source, toOffset: destination)
                            }
                        }
                    }

                    if let subscriptionsError {
                        Text(subscriptionsError)
                            .foregroundStyle(.red)
                    }
                } else {
                    Section {
                        PlaylistAppearancePicker(icon: $icon, accentColor: $accentColor)
                    }
                }

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
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if isDynamic && priorityList.count > 1 {
                        EditButton()
                    }
                    if isCreating {
                        ProgressView()
                    } else {
                        Button("Create") {
                            Task { await create() }
                        }
                        .disabled(isCreateDisabled)
                    }
                }
            }
            .task(id: isDynamic) {
                guard isDynamic, subscriptions.isEmpty else { return }
                await loadSubscriptions()
            }
        }
    }

    private var isCreateDisabled: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        return isDynamic && priorityList.isEmpty
    }

    private func loadSubscriptions() async {
        isLoadingSubscriptions = true
        subscriptionsError = nil
        do {
            subscriptions = try await subscriptionClient.getSubscriptions()
        } catch {
            subscriptionsError = "Something went wrong while loading your subscriptions. Please try again."
        }
        isLoadingSubscriptions = false
    }

    private func showTitle(for showId: String) -> String {
        subscriptions.first { $0.showId == showId }?.showTitle ?? showId
    }

    private func create() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if isDynamic && priorityList.isEmpty { return }

        isCreating = true
        errorMessage = nil
        do {
            let config = isDynamic
                ? DynamicPlaylistConfig(showIds: priorityList, maxEpisodes: maxEpisodes, priorityList: priorityList)
                : nil
            try await onCreate(trimmed, icon, accentColor, config)
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
