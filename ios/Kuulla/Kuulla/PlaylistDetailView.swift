import SwiftUI

struct PlaylistDetailView: View {
    let playlistId: String

    @Environment(\.playlistSyncEngine) private var syncEngine
    @Environment(\.scenePhase) private var scenePhase

    @State private var playlist: PlaylistDetail?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var mutationError: String?

    private let playlistClient = PlaylistClient()

    var body: some View {
        List {
            if let playlist {
                if playlist.type == .dynamic {
                    DynamicPlaylistConfigEditorView(playlist: Binding(
                        get: { playlist },
                        set: { updated in self.playlist = updated }
                    )) { config in
                        _ = try await playlistClient.updateDynamicPlaylistConfig(id: playlistId, config: config)
                        await load()
                    }
                } else if playlist.items.isEmpty {
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
                if let playlist, playlist.type == .manual, playlist.items.count > 1 {
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
        .refreshable {
            await load()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Mirrors SettingsView's identical guard/trigger: re-fetch when this view resumes in
            // the foreground, so a dynamic playlist's server-side auto-insertions/evictions (#112)
            // — which can land at any time a subscribed show's feed refreshes, not just in
            // response to something this device did — show up without a manual pull.
            guard newPhase == .active, playlist != nil else { return }
            Task { await refreshFromRemote() }
        }
    }

    private func refreshFromRemote() async {
        // GetPlaylistDetailAsync (src/Kuulla.Api/Services/PlaylistService.cs) always returns
        // current server state, so load() alone already reflects auto-insertions/evictions —
        // syncing first only matters for flushing this device's own pending local writes (a
        // manual reorder/remove) before re-fetching, same rationale as SettingsView.refreshFromRemote.
        await syncEngine?.syncNow()
        await load()
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

private struct DynamicPlaylistConfigEditorView: View {
    @Binding var playlist: PlaylistDetail
    let onSave: (DynamicPlaylistConfig) async throws -> Void

    @State private var maxEpisodes: Int
    @State private var priorityList: [String]
    @State private var pendingShowId = ""
    @State private var isLoadingSubscriptions = true
    @State private var subscriptionsError: String?
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var subscriptions: [Subscription] = []

    private let subscriptionClient = SubscriptionClient()

    init(playlist: Binding<PlaylistDetail>, onSave: @escaping (DynamicPlaylistConfig) async throws -> Void) {
        self._playlist = playlist
        self.onSave = onSave
        self._maxEpisodes = State(initialValue: playlist.wrappedValue.dynamicConfig?.maxEpisodes ?? 20)
        self._priorityList = State(initialValue: playlist.wrappedValue.dynamicConfig?.priorityList ?? playlist.wrappedValue.dynamicConfig?.showIds ?? [])
    }

    private var availableSubscriptions: [Subscription] {
        subscriptions
            .filter { !priorityList.contains($0.showId) }
            .sorted { $0.showTitle.localizedCaseInsensitiveCompare($1.showTitle) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Max episodes")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Stepper(value: $maxEpisodes, in: 1...100) {
                    Text("\(maxEpisodes)")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Add a podcast")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack {
                    Picker("Podcast", selection: $pendingShowId) {
                        Text("Choose a podcast")
                            .tag("")
                        ForEach(availableSubscriptions, id: \.showId) { subscription in
                            Text(subscription.showTitle)
                                .tag(subscription.showId)
                        }
                    }
                    .frame(maxWidth: .infinity)

                    Button("Add") {
                        guard !pendingShowId.isEmpty else { return }
                        if !priorityList.contains(pendingShowId) {
                            priorityList.append(pendingShowId)
                            pendingShowId = ""
                        }
                    }
                    .disabled(pendingShowId.isEmpty)
                }
            }

            if priorityList.isEmpty {
                Text("No podcasts selected yet. Episodes are pulled from the highest-priority podcast first.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Priority order")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    List {
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
                            .padding(.vertical, 4)
                        }
                        .onMove { source, destination in
                            priorityList.move(fromOffsets: source, toOffset: destination)
                        }
                    }
                    .frame(maxHeight: 260)
                    .listStyle(.plain)
                }
            }

            if let subscriptionsError {
                Text(subscriptionsError)
                    .foregroundStyle(.red)
            }

            if let saveError {
                Text(saveError)
                    .foregroundStyle(.red)
            }

            Button(action: save) {
                if isSaving {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    Text("Save")
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(isSaving || priorityList.isEmpty)
            .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 8)
        .task {
            await loadSubscriptions()
        }
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

    private func save() {
        Task {
            do {
                isSaving = true
                saveError = nil
                let config = DynamicPlaylistConfig(showIds: priorityList, maxEpisodes: maxEpisodes, priorityList: priorityList)
                try await onSave(config)
                playlist.dynamicConfig = config
            } catch {
                saveError = "Something went wrong while saving. Please try again."
            }
            isSaving = false
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
