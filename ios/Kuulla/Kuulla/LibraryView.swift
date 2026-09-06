import SwiftUI

struct LibraryView: View {
    @State private var subscriptions: [Subscription] = []
    @State private var playlists: [Playlist] = []
    @State private var unplayedCounts: [String: UnplayedCounts.Count] = [:]
    @State private var inProgressShowIds: Set<String> = []
    @State private var episodeStateLoaded = false
    @State private var isLoadingShows = false
    @State private var isLoadingPlaylists = false
    @State private var showsErrorMessage: String?
    @State private var playlistsErrorMessage: String?
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
    // Nil until the best-effort episode-state fetch in loadShows() completes, so the grid never
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

    private let subscriptionClient = SubscriptionClient()
    private let playlistClient = PlaylistClient()
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
                sortMenu
            }
            ToolbarItem(placement: .topBarTrailing) {
                ShowIconSizeMenu()
            }
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
            async let sortTask: Void = loadSortOrder()
            _ = await (showsTask, playlistsTask, sortTask)
        }
        .refreshable {
            async let showsTask: Void = loadShows()
            async let playlistsTask: Void = loadPlaylists()
            _ = await (showsTask, playlistsTask)
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort shows", selection: sortOrderBinding) {
                ForEach(SubscriptionSortOrder.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            Divider()
            Toggle("Hide caught-up shows", isOn: hideCaughtUpBinding)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Sort shows")
        .disabled(subscriptions.isEmpty && showsErrorMessage == nil)
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

    private func loadSortOrder() async {
        guard let settings = try? await settingsClient.getSettings(), !Task.isCancelled else { return }
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
                            ShowTile(subscription: subscription, unplayedCount: unplayedCounts[subscription.showId])
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
                        subscription: subscription, unplayedCount: unplayedCounts[subscription.showId])
                }
                .onMove(perform: moveSubscription)
            }
            .listStyle(.plain)
            .scrollDisabled(true)
            .environment(\.editMode, .constant(.active))
            .frame(height: max(1, CGFloat(subscriptions.count)) * 64)
        }
    }

    private func loadShows() async {
        guard !isLoadingShows else { return }
        isLoadingShows = true
        showsErrorMessage = nil

        do {
            let results = sortedSubscriptions(
                try await subscriptionClient.getSubscriptions(), by: sortOrder, manualOrder: manualOrder)
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
        // so a failure here shouldn't hide the already-loaded show grid behind an error. The same
        // data also drives the caught-up hide/sink, gated on episodeStateLoaded so nothing is
        // hidden until both fetches have actually landed. Fetched concurrently — neither depends
        // on the other.
        async let newEpisodesTask = subscriptionClient.getNewEpisodes()
        async let inProgressTask = subscriptionClient.getInProgressShowIds()
        let newEpisodes = try? await newEpisodesTask
        let inProgress = try? await inProgressTask
        guard !Task.isCancelled else { return }
        if let newEpisodes {
            unplayedCounts = UnplayedCounts.compute(from: newEpisodes)
        }
        if let inProgress {
            inProgressShowIds = inProgress
        }
        if newEpisodes != nil, inProgress != nil {
            episodeStateLoaded = true
        }
    }

    private func loadPlaylists() async {
        guard !isLoadingPlaylists else { return }
        isLoadingPlaylists = true
        playlistsErrorMessage = nil
        defer { isLoadingPlaylists = false }

        do {
            // Excludes "Up Next" — it's a regular playlist under the hood (see UpNextView), but
            // it already has its own dedicated shelf tile above, so listing it again here would
            // show a duplicate "Up Next" entry once the queue playlist gets created.
            let results = try await playlistClient.getPlaylists()
                .filter { $0.name != UpNextView.upNextPlaylistName }
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
    let unplayedCount: UnplayedCounts.Count?

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
