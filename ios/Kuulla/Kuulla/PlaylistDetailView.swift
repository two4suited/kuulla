import SwiftData
import SwiftUI

struct PlaylistDetailView: View {
    let playlistId: String

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext

    @State private var playlist: PlaylistDetail?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var mutationError: String?
    @State private var isShowingEditSheet = false
    @State private var isShowingRulesSheet = false
    // Set by a row's play button (#597) — a Button rather than a NavigationLink (unlike the row
    // itself), since List gives a second nested NavigationLink its own disclosure chevron, which
    // renders as a confusing duplicate next to the row's own. Routed through this separate
    // item-based destination instead.
    @State private var playTarget: PlaylistEpisodePlayTarget?

    private let playlistClient = PlaylistClient()

    var body: some View {
        List {
            if let playlist {
                if playlist.items.isEmpty {
                    Text(playlist.type == .dynamic
                        ? "This dynamic playlist currently resolves to no episodes. Adjust its rules to add podcasts or raise the episode limit."
                        : "This playlist is empty. Add episodes to it from a show or episode page.")
                        .foregroundStyle(.secondary)
                } else if playlist.type == .dynamic {
                    // A dynamic playlist's items are server-computed from its rules — not
                    // user-editable in place, so no onDelete/onMove here (edit the rules instead).
                    ForEach(playlist.items) { item in itemLink(item) }
                } else {
                    ForEach(playlist.items) { item in itemLink(item) }
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
            ToolbarItem(placement: .principal) {
                if let playlist {
                    HStack(spacing: 6) {
                        if let icon = playlist.icon, !icon.isEmpty {
                            Text(icon)
                                .foregroundStyle(Color(playlistAccentHex: playlist.accentColor) ?? .primary)
                        }
                        Text(playlist.name)
                            .font(.headline)
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if let playlist, playlist.type == .manual, playlist.items.count > 1 {
                    EditButton()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if let playlist, playlist.type == .dynamic {
                    Button {
                        isShowingRulesSheet = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("Edit playlist rules")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if playlist != nil {
                    Button {
                        isShowingEditSheet = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .accessibilityLabel("Edit playlist")
                }
            }
            ToolbarItem(placement: .bottomBar) {
                if let firstItem = playlist?.items.first {
                    NavigationLink(value: route(for: firstItem, autoPlay: true)) {
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
        .sheet(isPresented: $isShowingEditSheet) {
            if let playlist {
                EditPlaylistSheet(
                    name: playlist.name,
                    icon: playlist.icon,
                    accentColor: playlist.accentColor
                ) { newName, newIcon, newAccent in
                    _ = try await playlistClient.renamePlaylist(
                        id: playlistId, name: newName, icon: newIcon, accentColor: newAccent)
                    self.playlist?.name = newName
                    self.playlist?.icon = newIcon
                    self.playlist?.accentColor = newAccent
                }
                .presentationDetents([.medium, .large])
            }
        }
        .sheet(isPresented: $isShowingRulesSheet) {
            if let loaded = playlist {
                DynamicPlaylistRulesSheet(playlist: Binding(
                    get: { self.playlist ?? loaded },
                    set: { self.playlist = $0 }
                )) { config in
                    _ = try await playlistClient.updateDynamicPlaylistConfig(id: playlistId, config: config)
                    await load()
                }
            }
        }
        .task(id: playlistId) {
            await load()
        }
        .refreshable {
            await load()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Mirrors SettingsView's guard/trigger shape (re-fetch on foreground resume), but
            // skips SettingsView's syncEngine.syncNow() step — this view reloads via
            // GET /api/playlists/{id} (src/Kuulla.Api/Services/PlaylistService.cs), which always
            // returns current server state, so a re-fetch alone already reflects a dynamic
            // playlist's server-side auto-insertions/evictions (#112). KuullaApp already runs
            // playlistSyncEngine.syncNow() on this same scenePhase transition for pushing this
            // device's own pending local writes — no need to duplicate that call here.
            guard newPhase == .active, playlist != nil else { return }
            Task { await load() }
        }
        .navigationDestination(item: $playTarget) { target in
            EpisodeDetailView(
                showId: target.showId, episodeId: target.episodeId,
                playlistId: playlist?.type == .manual ? playlistId : nil,
                autoPlayOnAppear: true)
        }
    }

    @ViewBuilder
    private func itemLink(_ item: PlaylistItemDetail) -> some View {
        NavigationLink(value: route(for: item)) {
            PlaylistItemRow(item: item, onPlay: {
                playTarget = PlaylistEpisodePlayTarget(showId: item.showId, episodeId: item.episodeId)
            })
        }
    }

    // Manual playlists route through `.playlistEpisode` so EpisodeDetailView arms PlaybackQueue
    // for auto-advance (#532); dynamic playlists (rule-computed, not editable in place) stay on
    // the plain `.episode` route and don't auto-advance/auto-remove.
    private func route(for item: PlaylistItemDetail, autoPlay: Bool = false) -> CatalogRoute {
        if playlist?.type == .manual {
            return .playlistEpisode(playlistId: playlistId, showId: item.showId, episodeId: item.episodeId, autoPlay: autoPlay)
        }
        return .episode(showId: item.showId, episodeId: item.episodeId, autoPlay: autoPlay)
    }

    // Paints instantly from the locally-synced PlaylistRecord (kept current by PlaylistSyncAdapter,
    // same as PlaylistsView's list) while the network fetch below resolves server-authoritative
    // titles/artwork and (for dynamic playlists) the server-recomputed item set — instead of
    // blanking the whole screen behind a spinner on every appearance/refresh/resume.
    private func load() async {
        loadError = nil
        if playlist == nil, let local = localPlaceholder() {
            playlist = local
        }
        isLoading = playlist == nil

        do {
            // nil here means the playlist was actually deleted server-side (404) — correctly
            // clears a stale local placeholder rather than being treated as a fetch failure.
            playlist = try await playlistClient.getPlaylistDetail(id: playlistId)
        } catch {
            if !Task.isCancelled && playlist == nil {
                loadError = "Something went wrong while loading this playlist. Please try again."
            }
        }
        isLoading = false
    }

    // Builds a PlaylistDetail-shaped snapshot from the local sync store, resolving each item's
    // title/artwork against CatalogCache when available (best-effort — a show the cache hasn't
    // seen yet just shows the existing "(episode unavailable)" placeholder text until the network
    // fetch above lands).
    private func localPlaceholder() -> PlaylistDetail? {
        let id = playlistId
        guard let record = try? modelContext.fetch(
            FetchDescriptor<PlaylistRecord>(predicate: #Predicate { $0.id == id })
        ).first, !record.deleted else { return nil }

        // Resolve each distinct show once (not once per item), mirroring
        // PlaylistService.GetPlaylistDetailAsync's server-side comment for the same reason — a
        // playlist with many episodes from the same show shouldn't re-fetch that show's cached
        // episode list per item.
        let showIds = Set(record.items.map(\.showId))
        let episodesByShow = Dictionary(uniqueKeysWithValues: showIds.map {
            ($0, CatalogCache.episodes(showId: $0, in: modelContext))
        })
        let showsById = Dictionary(uniqueKeysWithValues: showIds.map {
            ($0, CatalogCache.show(id: $0, in: modelContext))
        })

        let items = record.items
            .sorted { $0.order < $1.order }
            .map { item -> PlaylistItemDetail in
                let episode = episodesByShow[item.showId]?.first { $0.id == item.episodeId }
                let show = showsById[item.showId] ?? nil
                return PlaylistItemDetail(
                    episodeId: item.episodeId, showId: item.showId,
                    title: episode?.title, artworkUrl: show?.artworkUrl,
                    addedAt: item.addedAt, order: item.order)
            }

        return PlaylistDetail(
            id: record.id, name: record.name, type: record.type, items: items,
            createdAt: record.createdAt, updatedAt: record.updatedAt,
            dynamicConfig: record.dynamicConfig.map {
                DynamicPlaylistConfig(showIds: $0.showIds, maxEpisodes: $0.maxEpisodes, priorityList: $0.priorityList)
            },
            icon: record.icon, accentColor: record.accentColor)
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

// The dynamic-playlist rule editor (max episodes / podcast picker / priority order), presented as
// a sheet off PlaylistDetailView's "rules" toolbar button (#512) — the detail view itself now
// always lists the playlist's resolved episodes, for dynamic and manual playlists alike.
private struct DynamicPlaylistRulesSheet: View {
    @Environment(\.dismiss) private var dismiss

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
        NavigationStack {
            Form {
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
                        Text("No podcasts selected yet. Episodes are pulled from the highest-priority podcast first.")
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

                if let saveError {
                    Text(saveError)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("Playlist rules")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if priorityList.count > 1 {
                        EditButton()
                    }
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save", action: save)
                            .disabled(priorityList.isEmpty)
                    }
                }
            }
            .task {
                await loadSubscriptions()
            }
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
                dismiss()
            } catch {
                saveError = "Something went wrong while saving. Please try again."
            }
            isSaving = false
        }
    }
}

// Rename + icon/accent editor for an existing playlist (#439). Sends the playlist's full display
// state on save (PUT /api/playlists/{id} replaces, it doesn't patch).
private struct EditPlaylistSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var icon: String?
    @State private var accentColor: String?
    @State private var isSaving = false
    @State private var errorMessage: String?

    let onSave: (String, String?, String?) async throws -> Void

    init(
        name: String,
        icon: String?,
        accentColor: String?,
        onSave: @escaping (String, String?, String?) async throws -> Void
    ) {
        self._name = State(initialValue: name)
        self._icon = State(initialValue: icon)
        self._accentColor = State(initialValue: accentColor)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Playlist name", text: $name)
                Section {
                    PlaylistAppearancePicker(icon: $icon, accentColor: $accentColor)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("Edit Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") {
                            Task { await save() }
                        }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }

    private func save() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isSaving = true
        errorMessage = nil
        do {
            try await onSave(trimmed, icon, accentColor)
            dismiss()
        } catch {
            errorMessage = "Something went wrong while saving. Please try again."
        }
        isSaving = false
    }
}

// Identifies which episode a row's play button targets — Hashable so it can drive
// .navigationDestination(item:).
private struct PlaylistEpisodePlayTarget: Identifiable, Hashable {
    let showId: String
    let episodeId: String
    var id: String { episodeId }
}

private struct PlaylistItemRow: View {
    let item: PlaylistItemDetail
    let onPlay: () -> Void

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

            Spacer()

            // A plain Button (not NavigationLink, unlike the row itself) — List's UIKit-backed
            // row hosting reliably gives this its own tap target separate from the row (matches
            // the same pattern in ShowDetailView.EpisodeRow), so tapping it plays the episode
            // instead of just opening it. A nested NavigationLink here would work the same way
            // for taps, but List also gives it its own disclosure chevron — a confusing second
            // one next to the row's own.
            Button(action: onPlay) {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play episode")
        }
    }
}

#Preview {
    NavigationStack {
        PlaylistDetailView(playlistId: "preview-playlist")
    }
}
