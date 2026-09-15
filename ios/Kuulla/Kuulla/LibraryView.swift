import SwiftData
import SwiftUI

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.playlistSyncEngine) private var playlistSyncEngine
    @Environment(\.settingsSyncEngine) private var settingsSyncEngine
    @Environment(\.catalogRefresh) private var catalogRefresh

    @State private var subscriptions: [Subscription] = []
    @State private var playlists: [PlaylistSummary] = []
    @State private var unplayedCounts: [String: UnplayedCounts.Count] = [:]
    @State private var inProgressShowIds: Set<String> = []
    @State private var episodeStateLoaded = false
    // Stays false only until the first (synchronous) read of the local catalog cache lands.
    @State private var hasLoadedLocalShows = false
    @State private var isSyncingPlaylists = false
    // Stays false only until the first (synchronous) read of the local playlist store lands.
    @State private var hasLoadedLocalPlaylists = false
    @State private var showsErrorMessage: String?
    @State private var sortOrder: SubscriptionSortOrder = .title
    @State private var sortSaveTask: Task<Void, Never>?
    @State private var sortSaveError: String?
    @State private var manualOrder: [String] = []
    @State private var manualSaveTask: Task<Void, Never>?
    @State private var manualSaveError: String?
    @State private var hideCaughtUpShows = false
    @State private var hideCaughtUpSaveTask: Task<Void, Never>?
    @State private var hideCaughtUpSaveError: String?

    // Shows with at least one unplayed or in-progress episode — the complement of "caught up".
    // Nil until the local catalog snapshot has been read in readLocalShows(), so the grid never
    // hides or re-sinks shows on incomplete data.
    private var activeShowIds: Set<String>? {
        episodeStateLoaded ? Set(unplayedCounts.keys).union(inProgressShowIds) : nil
    }

    // Render order for the grid: the stored `subscriptions` order with the caught-up sink (and,
    // when enabled, the hide filter) layered on. `subscriptions` itself stays the full list.
    private var displayedSubscriptions: [Subscription] {
        sortedSubscriptions(
            subscriptions, by: sortOrder, manualOrder: manualOrder,
            activeShowIds: activeShowIds, hideCaughtUp: hideCaughtUpShows)
    }

    @AppStorage(ShowIconSize.storageKey) private var iconSizeRaw = ShowIconSize.default.rawValue

    private let settingsClient = SettingsClient()

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: ShowIconSize.current(iconSizeRaw).gridMinimum), spacing: 16)]
    }

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
                ShowDisplaySettingsMenu(
                    sortOrder: sortOrderBinding,
                    hideCaughtUpShows: hideCaughtUpBinding,
                    isDisabled: subscriptions.isEmpty && showsErrorMessage == nil)
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(destination: FeedView()) {
                    Image(systemName: "bell")
                }
                .accessibilityLabel("New Episodes")
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: CatalogRoute.settings) {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
        }
        .task {
            // Local-only paint (#488): no network here. The catalog is refreshed on cold
            // launch (KuullaApp), by pull-to-refresh below, or by Settings → "Sync Now".
            await loadSortOrder()
            readLocalShows()
            await loadPlaylists()
        }
        .refreshable {
            await catalogRefresh?.refreshAll()
            await loadSortOrder()
            readLocalShows()
            readLocalPlaylists()
        }
        .onAppear {
            // Cheap local re-read on every return to the tab — the shared TabView keeps this view
            // alive so `.task` runs only once, and a sync triggered elsewhere won't otherwise
            // reach these shelves.
            readLocalShows()
            readLocalPlaylists()
        }
        .onChange(of: catalogRefresh?.isRefreshing) { _, _ in
            // The cold-launch refresh (or a "Sync Now" run from Settings) finishing needs to
            // reach this already-visible screen — re-read the cache when isRefreshing flips.
            readLocalShows()
        }
        .onChange(of: CatalogCacheSignal.shared.version) { _, _ in
            // A point patch (natural finish, CarPlay, the completed toggle elsewhere) landed
            // while this screen is already on-screen (#772) — nothing else would repaint it.
            readLocalShows()
        }
    }

    private var hideCaughtUpBinding: Binding<Bool> {
        Binding(
            get: { hideCaughtUpShows },
            set: { newValue in
                let previous = hideCaughtUpShows
                guard newValue != previous else { return }
                hideCaughtUpShows = newValue
                hideCaughtUpSaveError = nil
                // Optimistic, with rollback on failure — matches the sort-order binding.
                hideCaughtUpSaveTask?.cancel()
                hideCaughtUpSaveTask = Task {
                    do {
                        _ = try await settingsClient.updateHideCaughtUpShows(newValue)
                    } catch {
                        guard !Task.isCancelled else { return }
                        hideCaughtUpShows = previous
                        hideCaughtUpSaveError = "Couldn't save your choice. Please try again."
                    }
                }
            })
    }

    private var sortOrderBinding: Binding<SubscriptionSortOrder> {
        Binding(
            get: { sortOrder },
            set: { newValue in
                let previous = sortOrder
                guard newValue != previous else { return }
                sortOrder = newValue
                subscriptions = sortedSubscriptions(subscriptions, by: newValue, manualOrder: manualOrder)
                sortSaveError = nil
                manualSaveError = nil
                persistSortOrder(newValue, revertingTo: previous)
            })
    }

    // Reads the locally-synced settings mirror (UserSettingsRecord) rather than GET /api/settings
    // (#488) — the settings sync domain is refreshed on cold launch and by "Sync Now".
    private func loadSortOrder() async {
        guard let engine = settingsSyncEngine else { return }
        let id = UserSettingsRecord.localId
        let record = try? await engine.read { context in
            try context.fetch(FetchDescriptor<UserSettingsRecord>(predicate: #Predicate { $0.id == id })).first
        }
        guard let settings = (record ?? nil)?.asUserSettings, !Task.isCancelled else { return }
        sortOrder = settings.subscriptionSortOrder
        manualOrder = settings.subscriptionManualOrder
        hideCaughtUpShows = settings.hideCaughtUpShows
        subscriptions = sortedSubscriptions(subscriptions, by: sortOrder, manualOrder: manualOrder)
    }

    // Reorder within the manual list: apply the move locally, then persist the full showId
    // array (last-write-wins on the whole array, per #438). Rolls back on failure.
    private func moveSubscription(from offsets: IndexSet, to destination: Int) {
        subscriptions.move(fromOffsets: offsets, toOffset: destination)
        let previous = manualOrder
        let newOrder = subscriptions.map(\.showId)
        manualOrder = newOrder
        manualSaveError = nil
        manualSaveTask?.cancel()
        manualSaveTask = Task {
            do {
                _ = try await settingsClient.updateSubscriptionManualOrder(newOrder)
            } catch {
                guard !Task.isCancelled else { return }
                manualOrder = previous
                subscriptions = sortedSubscriptions(subscriptions, by: .manual, manualOrder: previous)
                manualSaveError = "Couldn't save the new order. Please try again."
            }
        }
    }

    // Cancels an in-flight save when a new choice comes in so the last pick wins, mirroring
    // SettingsView's saveTask pattern. On failure the optimistic change is rolled back and an
    // error is shown, matching the web pages — a silently-dropped save would otherwise revert
    // itself on the next launch with no explanation.
    private func persistSortOrder(_ newValue: SubscriptionSortOrder, revertingTo previous: SubscriptionSortOrder) {
        sortSaveTask?.cancel()
        sortSaveTask = Task {
            do {
                _ = try await settingsClient.updateSubscriptionSortOrder(newValue)
            } catch {
                guard !Task.isCancelled else { return }
                sortOrder = previous
                subscriptions = sortedSubscriptions(subscriptions, by: previous, manualOrder: manualOrder)
                sortSaveError = "Couldn't save your sort choice. Please try again."
            }
        }
    }

    private var playlistsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Playlists")
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            if !hasLoadedLocalPlaylists {
                ProgressView()
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
                                    subtitle: "\(playlist.itemCount) episode\(playlist.itemCount == 1 ? "" : "s")",
                                    isEnabled: true,
                                    emoji: playlist.icon,
                                    accentHex: playlist.accentColor)
                            }
                            .buttonStyle(.plain)
                        }

                        NavigationLink(value: CatalogRoute.downloads) {
                            ShelfTile(systemImage: "arrow.down.circle", title: "Downloads", subtitle: "Manage", isEnabled: true)
                        }
                        .buttonStyle(.plain)
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

            if let sortSaveError {
                Text(sortSaveError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }
            if let hideCaughtUpSaveError {
                Text(hideCaughtUpSaveError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }
            if let manualSaveError {
                Text(manualSaveError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            if !hasLoadedLocalShows {
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
            } else if sortOrder == .manual {
                manualReorderList
            } else if displayedSubscriptions.isEmpty {
                Text("You're caught up on every show. Turn off \u{201C}Hide caught-up shows\u{201D} to see them all.")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            } else {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(displayedSubscriptions) { subscription in
                        NavigationLink(value: CatalogRoute.show(id: subscription.showId)) {
                            ShowTile(
                            subscription: subscription,
                            unplayedCount: unplayedCounts[subscription.showId],
                            isInProgress: inProgressShowIds.contains(subscription.showId))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    // A non-scrolling List embedded in the page's outer ScrollView, held in edit mode so the
    // reorder grips are always visible — drag to rearrange, changes persist per move.
    private var manualReorderList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Drag to reorder. Your arrangement syncs across devices.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            List {
                ForEach(subscriptions) { subscription in
                    SubscriptionManualReorderRow(
                        subscription: subscription,
                        unplayedCount: unplayedCounts[subscription.showId],
                        isInProgress: inProgressShowIds.contains(subscription.showId))
                }
                .onMove(perform: moveSubscription)
            }
            .listStyle(.plain)
            .scrollDisabled(true)
            .environment(\.editMode, .constant(.active))
            .frame(height: max(1, CGFloat(subscriptions.count)) * 64)
        }
    }

    // Synchronous paint from the on-device catalog cache (#488) — no network. The cache is
    // filled by CatalogRefreshService on cold launch, pull-to-refresh, and Settings → "Sync Now".
    private func readLocalShows() {
        subscriptions = sortedSubscriptions(
            CatalogCache.subscriptions(in: modelContext), by: sortOrder, manualOrder: manualOrder)
        unplayedCounts = CatalogCache.unplayedCounts(in: modelContext)
        inProgressShowIds = CatalogCache.inProgressShowIds(in: modelContext)
        // The caught-up sink/hide keys off this; the cache always has a (possibly empty) snapshot.
        episodeStateLoaded = true
        hasLoadedLocalShows = true
        showsErrorMessage = nil
    }

    // Paint the playlist shelf from the local sync store immediately, then let the playlist
    // SyncEngine refresh from the server behind the already-visible tiles (#511).
    private func loadPlaylists() async {
        readLocalPlaylists()
        guard !isSyncingPlaylists else { return }
        isSyncingPlaylists = true
        defer { isSyncingPlaylists = false }
        await playlistSyncEngine?.syncNow()
        guard !Task.isCancelled else { return }
        guard let playlistSyncEngine else {
            readLocalPlaylists()
            return
        }
        // Read back through the engine's own ModelContext, not this view's — the same instance
        // syncNow() just saved into. See SyncEngine.read's doc comment.
        let records = await playlistSyncEngine.read { context in
            (try? context.fetch(FetchDescriptor<PlaylistRecord>())) ?? []
        }
        playlists = PlaylistSummary.list(from: records, excludingUpNext: true)
        hasLoadedLocalPlaylists = true
    }

    private func readLocalPlaylists() {
        // Excludes "Up Next" — it's a regular playlist under the hood (see UpNextView), but it
        // already has its own dedicated shelf tile above, so listing it again here would show a
        // duplicate "Up Next" entry once the queue playlist gets created.
        let records = (try? modelContext.fetch(FetchDescriptor<PlaylistRecord>())) ?? []
        playlists = PlaylistSummary.list(from: records, excludingUpNext: true)
        hasLoadedLocalPlaylists = true
    }
}

private struct ShelfTile: View {
    let systemImage: String
    let title: String
    let subtitle: String
    let isEnabled: Bool
    var emoji: String? = nil
    var accentHex: String? = nil

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let emoji, !emoji.isEmpty {
                    Text(emoji)
                        .foregroundStyle(Color(playlistAccentHex: accentHex) ?? .primary)
                } else {
                    Image(systemName: systemImage)
                }
            }
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
    let unplayedCount: UnplayedCounts.Count?
    var isInProgress = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Drive the square off a zero-intrinsic-size Color.clear box rather than putting
            // .aspectRatio directly on the AsyncImage: a tall source image otherwise stretches
            // the tile vertically because AsyncImage reports the loaded image's own size (#519).
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    AsyncImage(url: subscription.showArtworkUrl.flatMap(URL.init)) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Color.secondary.opacity(0.2)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))

            if let unplayedCount, unplayedCount.unplayed > 0 {
                Text(unplayedCount.hitCap ? "\(unplayedCount.unplayed)+" : "\(unplayedCount.unplayed)")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.accentColor, in: Capsule())
                    .padding(4)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if isInProgress {
                InProgressShowBadge()
                    .padding(4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isInProgress ? "\(subscription.showTitle), in progress" : subscription.showTitle)
    }
}

#Preview {
    NavigationStack {
        LibraryView()
    }
}
