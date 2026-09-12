import SwiftData
import SwiftUI

struct ShowDetailView: View {
    let showId: String

    @Environment(\.episodeSyncEngine) private var syncEngine
    @Environment(\.settingsSyncEngine) private var settingsSyncEngine
    @Environment(\.catalogRefresh) private var catalogRefresh
    @Environment(\.modelContext) private var modelContext

    @State private var show: Show?
    @State private var isLoadingShow = false
    @State private var showError: String?
    @State private var episodes: [Episode] = []
    @State private var statusByEpisodeId: [String: EpisodeStatus] = [:]
    @State private var downloadStatusByEpisodeId: [String: DownloadStatus] = [:]
    @State private var positionSecondsByEpisodeId: [String: Int] = [:]
    @State private var archivedEpisodeIds: Set<String> = []
    @State private var selectedFilter: EpisodeFilter = .unfinished
    @State private var selectedSort: EpisodeSortOrder = .newestFirst
    @State private var continuationToken: String?
    @State private var isLoadingEpisodes = false
    @State private var episodeError: String?
    @State private var isSubscribed = false
    @State private var isSubscriptionBusy = false
    @State private var subscriptionError: String?
    // Set once the user has manually subscribed/unsubscribed, so the initial (slower)
    // subscription-status fetch doesn't clobber a faster, more current toggle result.
    @State private var hasToggledSubscription = false
    @State private var isShowingSettings = false
    @State private var addToPlaylistEpisode: Episode?
    @State private var isConfirmingMarkAllPlayed = false
    @State private var isMarkingAllPlayed = false
    @State private var markAllPlayedError: String?
    // Loaded once per view lifecycle (loadShow()), mirroring EpisodeDetailView's @State
    // autoDeleteRule — avoids a settings network round trip on every swipe-to-mark-played (#532).
    @State private var autoDeleteRule: AutoDeleteRule = .never
    @State private var leadingSwipeActions: [EpisodeSwipeAction] = []
    @State private var trailingSwipeActions: [EpisodeSwipeAction] = [.addToPlaylist, .markPlayed]
    @State private var addToUpNextError: String?
    @State private var downloadManager = DownloadManager.shared

    private let catalogClient = PodcastCatalogClient()
    private let subscriptionClient = SubscriptionClient()
    private let episodeStateClient = EpisodeStateClient()
    private let settingsClient = SettingsClient()
    private let playlistClient = PlaylistClient()

    var body: some View {
        List {
            if let show {
                Section {
                    ShowHeader(
                        show: show,
                        isSubscribed: isSubscribed,
                        isSubscriptionBusy: isSubscriptionBusy,
                        subscriptionError: subscriptionError,
                        onSubscribeTapped: { Task { await toggleSubscription() } }
                    )
                }
                .listRowSeparator(.hidden)
            } else if let showError {
                Text(showError)
                    .foregroundStyle(.red)
            } else if !isLoadingShow {
                Text("Show not found.")
                    .foregroundStyle(.secondary)
            }

            if show != nil || isLoadingEpisodes || episodeError != nil {
                Section("Episodes") {
                    if show != nil {
                        filterAndSortControls
                    }

                    if let episodeError {
                        Text(episodeError)
                            .foregroundStyle(.red)
                    } else if episodes.isEmpty && !isLoadingEpisodes {
                        Text("No episodes found for this show.")
                            .foregroundStyle(.secondary)
                    } else if displayedEpisodes.isEmpty && !isLoadingEpisodes {
                        Text("No episodes match this filter.")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(displayedEpisodes) { episode in
                        let status = statusByEpisodeId[episode.id] ?? .new
                        NavigationLink(value: CatalogRoute.episode(showId: showId, episodeId: episode.id)) {
                            EpisodeRow(
                                episode: episode,
                                artworkUrl: show?.artworkUrl,
                                status: status,
                                downloadStatus: downloadStatusByEpisodeId[episode.id],
                                // Only in-progress episodes get a bar — a played episode persists
                                // positionSeconds at the full duration, which would otherwise also
                                // satisfy EpisodeProgress.fraction's guards and render a (stale,
                                // misleading) near-full bar for an episode that's already done.
                                progressFraction: status == .inProgress
                                    ? EpisodeProgress.fraction(
                                        positionSeconds: positionSecondsByEpisodeId[episode.id] ?? 0,
                                        duration: episode.duration)
                                    : nil,
                                onPlay: {
                                    Task { await PlaybackQueue.shared.quickPlay(episodeId: episode.id, showId: showId, playlistId: nil) }
                                },
                                onRestore: { Task { await restoreAutoPlayed(episodeId: episode.id) } },
                                onDownloadDidFinish: refreshStatuses)
                        }
                        .accessibilityIdentifier("episode-row")
                        // allowsFullSwipe: false — a long/fast swipe only reveals the buttons, it
                        // never auto-triggers the first one. Any configured action can be a
                        // destructive-ish side effect (marking played feeds auto-archive /
                        // auto-delete afterPlayed rules; removing a download deletes a file), so
                        // none of them should fire from an accidental gesture (#540, #568).
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            ForEach(trailingSwipeActions) { action in
                                swipeActionButton(action, for: episode, status: status)
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            ForEach(leadingSwipeActions) { action in
                                swipeActionButton(action, for: episode, status: status)
                            }
                        }
                    }

                    if isLoadingEpisodes {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    } else if continuationToken != nil {
                        Button("Load more") {
                            Task { await loadMoreEpisodes() }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(show?.title ?? "Show")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        isShowingSettings = true
                    } label: {
                        Label("Podcast settings", systemImage: "gearshape")
                    }
                    Button {
                        isConfirmingMarkAllPlayed = true
                    } label: {
                        Label("Mark all played", systemImage: "checkmark.circle")
                    }
                    .disabled(isMarkingAllPlayed)
                    if isSubscribed {
                        Button(role: .destructive) {
                            Task { await toggleSubscription() }
                        } label: {
                            Label("Unsubscribe", systemImage: "bell.slash")
                        }
                        .disabled(isSubscriptionBusy)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Podcast actions")
                .disabled(show == nil)
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            ShowSettingsSheet(showId: showId, showTitle: show?.title ?? "Show")
        }
        .confirmationDialog(
            "Mark every episode of this show as played?",
            isPresented: $isConfirmingMarkAllPlayed,
            titleVisibility: .visible
        ) {
            Button("Mark all played") {
                Task { await markAllPlayed() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Couldn't mark episodes played", isPresented: markAllPlayedErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(markAllPlayedError ?? "")
        }
        .alert("Couldn't add to Up Next", isPresented: addToUpNextErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(addToUpNextError ?? "")
        }
        .sheet(item: $addToPlaylistEpisode) { episode in
            AddToPlaylistSheet(episodeId: episode.id, showId: showId)
        }
        .overlay {
            if isLoadingShow {
                ProgressView()
            }
        }
        .task(id: showId) {
            await loadShow()
        }
        .task {
            await loadSwipeActionSettings()
        }
        .refreshable {
            await catalogRefresh?.refreshShow(showId: showId)
            // Pull cross-device episode state too so in-progress bars are current (#513).
            await syncEngine?.syncNow(requestFollowUpIfSyncing: false)
            readLocalShow()
            // Network subscription check last so it wins over the cached value in readLocalShow().
            await loadSubscriptionStatus()
        }
        .onAppear {
            // Cheap local-only re-derivation (no network), mirroring FeedView, so a badge changed
            // from EpisodeDetailView isn't left stale when popping back to this screen.
            refreshStatuses()
        }
    }

    private func loadShow() async {
        show = nil
        showError = nil
        episodes = []
        statusByEpisodeId = [:]
        positionSecondsByEpisodeId = [:]
        selectedFilter = .unfinished
        selectedSort = .newestFirst
        continuationToken = nil
        episodeError = nil
        isLoadingEpisodes = false
        isSubscribed = false
        isSubscriptionBusy = false
        subscriptionError = nil
        hasToggledSubscription = false
        isConfirmingMarkAllPlayed = false
        isMarkingAllPlayed = false
        markAllPlayedError = nil

        // Paint from the on-device catalog cache first (#488) — instant, offline-capable.
        readLocalShow()

        // Best-effort, not on the critical path for painting the show — mirrors
        // EpisodeDetailView.loadPlaybackSettings's fire-and-forget pattern. Not needed until the
        // user actually marks something played, by which point this has long since resolved.
        Task { await loadAutoDeleteRule() }

        // Only hit the network when the cache has nothing for this show yet (first-ever visit,
        // or a show reached from Search/Discovery that isn't subscribed). Otherwise the cache
        // copy stands until the user pulls to refresh or runs Settings → "Sync Now".
        if show == nil {
            isLoadingShow = true
            do {
                if let fetched = try await catalogClient.getShow(id: showId) {
                    show = fetched
                    CatalogCache.upsertShow(fetched, in: modelContext)
                }
            } catch {
                if !Task.isCancelled {
                    showError = "Something went wrong while loading this show. Please try again."
                }
            }
            isLoadingShow = false

            // This show wasn't in our subscription cache (reached from Search/Discovery, or
            // subscribed on another device since the last sync) — confirm its real state from
            // the server. Shows already in the cache trust readLocalShow()'s value, no network.
            await loadSubscriptionStatus()
        }

        if show != nil, episodes.isEmpty, continuationToken == nil {
            await loadMoreEpisodes()
        }
    }

    // Best-effort: a failure here just leaves auto-delete-after-played disabled for this view's
    // lifetime, same fallback EpisodeDetailView.loadPlaybackSettings uses for the same setting.
    // Resolves show-override-else-global via the same helper as EpisodeDetailView, so a per-show
    // override (set via ShowSettingsSheet) is honored here too rather than only the global default.
    private func loadAutoDeleteRule() async {
        async let userSettings = try? settingsClient.getSettings()
        async let showSettings = try? settingsClient.getShowSettings(showId: showId)
        let (user, show) = await (userSettings, showSettings)
        autoDeleteRule = EpisodeDetailView.resolvedAutoDeleteRule(show: show, user: user)
    }

    // Best-effort network check of whether this show is subscribed, used when the local cache
    // can't answer. Leaves the button in its current state on failure.
    private func loadSubscriptionStatus() async {
        do {
            let subscriptions = try await subscriptionClient.getSubscriptions()
            guard !Task.isCancelled, !hasToggledSubscription else { return }
            isSubscribed = subscriptions.contains { $0.showId == showId }
        } catch {
            // Not authenticated or the call failed; leave the subscribe button as it was.
        }
    }

    // Synchronous read of the cached show + episode list + subscription state.
    private func readLocalShow() {
        show = CatalogCache.show(id: showId, in: modelContext) ?? show
        let cached = CatalogCache.episodes(showId: showId, in: modelContext)
        if !cached.isEmpty {
            episodes = cached
            continuationToken = CatalogCache.continuationToken(showId: showId, in: modelContext)
        }
        if !hasToggledSubscription {
            isSubscribed = CatalogCache.subscriptions(in: modelContext).contains { $0.showId == showId }
        }
        refreshStatuses()
    }

    private func toggleSubscription() async {
        guard !isSubscriptionBusy else { return }

        isSubscriptionBusy = true
        subscriptionError = nil
        hasToggledSubscription = true
        let previouslySubscribed = isSubscribed
        isSubscribed.toggle()

        do {
            if previouslySubscribed {
                try await subscriptionClient.unsubscribe(showId: showId)
                // Keep the local catalog cache in step so Library/Subscriptions reflect this
                // without waiting for the next "Sync Now" (#488).
                CatalogCache.removeSubscription(showId: showId, in: modelContext)
                CatalogCache.removeShowFromSnapshot(showId: showId, in: modelContext)
            } else {
                let created = try await subscriptionClient.subscribe(showId: showId)
                CatalogCache.upsertSubscription(created, in: modelContext)
                CatalogCache.recordNewSubscription(showId: showId, episodes: episodes, in: modelContext)
            }
        } catch {
            if !Task.isCancelled {
                isSubscribed = previouslySubscribed
                if case ApiError.requestFailed(let statusCode) = error, statusCode == 401 || statusCode == 403 {
                    subscriptionError = "Please sign in to subscribe to shows."
                } else {
                    subscriptionError = previouslySubscribed
                        ? "Something went wrong while unsubscribing. Please try again."
                        : "Something went wrong while subscribing. Please try again."
                }
            }
        }

        isSubscriptionBusy = false
    }

    private func loadMoreEpisodes() async {
        guard !isLoadingEpisodes else { return }

        isLoadingEpisodes = true
        episodeError = nil

        do {
            let isFirstPage = continuationToken == nil
            let page = try await catalogClient.getEpisodes(showId: showId, continuationToken: continuationToken)
            if isFirstPage {
                episodes = page.items
                CatalogCache.replaceEpisodes(
                    showId: showId, page.items, continuationToken: page.continuationToken, in: modelContext)
            } else {
                episodes.append(contentsOf: page.items)
                CatalogCache.appendEpisodes(
                    showId: showId, page.items, continuationToken: page.continuationToken, in: modelContext)
            }
            continuationToken = page.continuationToken
            refreshStatuses()
        } catch {
            if !Task.isCancelled {
                episodeError = "Something went wrong while loading episodes. Please try again."
            }
        }

        isLoadingEpisodes = false

        // Once the rows are on screen, reconcile episode state from the server so a playback
        // position set on another device (e.g. Web) populates the in-progress progress bar
        // (#513) — ShowDetail.razor does the equivalent with a per-page LoadEpisodeStatesAsync.
        // refreshStatuses() above only sees what the app-level background sync has already
        // pulled into the local store, which on a fresh launch or a just-updated episode it
        // may not have yet. requestFollowUpIfSyncing: false — we only need local state to be
        // fresh, not to force a second POST behind an in-flight sync.
        guard episodeError == nil else { return }
        await syncEngine?.syncNow(requestFollowUpIfSyncing: false)
        guard !Task.isCancelled else { return }
        refreshStatuses()
    }

    private var displayedEpisodes: [Episode] {
        EpisodeListFilter.apply(
            episodes: episodes, statuses: statusByEpisodeId, filter: selectedFilter, sort: selectedSort,
            archived: archivedEpisodeIds)
    }

    private var markAllPlayedErrorBinding: Binding<Bool> {
        Binding(
            get: { markAllPlayedError != nil },
            set: { if !$0 { markAllPlayedError = nil } })
    }

    private var addToUpNextErrorBinding: Binding<Bool> {
        Binding(
            get: { addToUpNextError != nil },
            set: { if !$0 { addToUpNextError = nil } })
    }

    // Reads the configured swipe-action sets from the local settings mirror (kept current by
    // Settings/app-level sync) — a one-shot read, not observed live, matching how this view
    // already treats every other setting it doesn't itself own.
    private func loadSwipeActionSettings() async {
        guard let settingsSyncEngine else { return }
        let id = UserSettingsRecord.localId
        let record = try? await settingsSyncEngine.read { context in
            try context.fetch(FetchDescriptor<UserSettingsRecord>(predicate: #Predicate { $0.id == id })).first
        }
        if let record {
            leadingSwipeActions = record.leadingSwipeActions
            trailingSwipeActions = record.trailingSwipeActions
        }
    }

    @ViewBuilder
    private func swipeActionButton(_ action: EpisodeSwipeAction, for episode: Episode, status: EpisodeStatus) -> some View {
        switch action {
        case .markPlayed:
            Button {
                Task { await toggleCompleted(episode: episode) }
            } label: {
                if status == .played {
                    Label("Mark as Unplayed", systemImage: "circle")
                } else {
                    Label("Mark as Played", systemImage: "checkmark.circle")
                }
            }
            .tint(.green)
        case .addToPlaylist:
            Button {
                addToPlaylistEpisode = episode
            } label: {
                Label("Add to Playlist", systemImage: "text.badge.plus")
            }
            .tint(.blue)
        case .download:
            let downloadStatus = DownloadButton.effectiveStatus(
                liveProgress: downloadManager.progress[episode.id],
                persistedStatus: downloadStatusByEpisodeId[episode.id])
            Button {
                toggleDownload(episode: episode, status: downloadStatus)
            } label: {
                if downloadStatus == .complete {
                    Label("Remove Download", systemImage: "trash")
                } else {
                    Label("Download", systemImage: "arrow.down.circle")
                }
            }
            .tint(.orange)
        case .addToUpNext:
            Button {
                Task { await addToUpNext(episode: episode) }
            } label: {
                Label("Add to Up Next", systemImage: "list.bullet.badge.plus")
            }
            .tint(.purple)
        }
    }

    private func toggleDownload(episode: Episode, status: DownloadStatus?) {
        switch status {
        case .complete:
            let episodeId = episode.id
            let descriptor = FetchDescriptor<DownloadedEpisodeRecord>(predicate: #Predicate { $0.id == episodeId })
            if let record = try? modelContext.fetch(descriptor).first, DownloadCleanup.delete([record], from: modelContext) {
                refreshStatuses()
            }
        case .downloading:
            downloadManager.cancelDownload(episodeId: episode.id)
        case .failed, nil:
            downloadManager.startDownload(episode: episode)
        }
    }

    // Resolves (or creates) the well-known "Up Next" playlist, same convention as
    // UpNextView.resolve(), then appends this episode to it.
    private func addToUpNext(episode: Episode) async {
        do {
            let playlists = try await playlistClient.getPlaylists()
            let upNextId: String
            if let existing = playlists
                .filter({ $0.name == UpNextView.upNextPlaylistName })
                .min(by: { $0.createdAt < $1.createdAt })
            {
                upNextId = existing.id
            } else {
                upNextId = try await playlistClient.createPlaylist(name: UpNextView.upNextPlaylistName).id
            }
            try await playlistClient.addItem(playlistId: upNextId, episodeId: episode.id, showId: showId)
        } catch {
            if !Task.isCancelled {
                addToUpNextError = "Something went wrong while adding to Up Next. Please try again."
            }
        }
    }

    // Marks the show's whole back catalogue played server-side in one call (#490), then pulls the
    // authoritative rows into the local store via the sync engine. The on-screen rows are updated
    // optimistically so the change is visible immediately; episodes on not-yet-loaded pages were
    // marked server-side too and render correctly once loaded.
    private func markAllPlayed() async {
        guard !isMarkingAllPlayed else { return }

        isMarkingAllPlayed = true
        markAllPlayedError = nil

        do {
            try await episodeStateClient.markAllPlayed(showId: showId)
            for episode in episodes {
                statusByEpisodeId[episode.id] = .played
                positionSecondsByEpisodeId[episode.id] = Int(episode.duration ?? 0)
            }
            // Whole back catalogue is now played, so the show has zero unplayed and can't be
            // in-progress — reuses the unsubscribe path's blob patch (#556).
            CatalogCache.removeShowFromSnapshot(showId: showId, in: modelContext)
            // #532: scoped to the whole show (not `episodes`, which only holds whatever page is
            // currently loaded) — this action marks the *entire* back catalogue played
            // server-side, so a downloaded episode on a not-yet-paginated page must be cleaned up
            // too, not just the ones currently in memory.
            for deletedId in DownloadCleanup.deleteAllEligible(
                forShowId: showId, autoDeleteRule: autoDeleteRule, in: modelContext
            ) {
                downloadStatusByEpisodeId[deletedId] = nil
            }
            // #569: same rule as the per-episode toggle above, scoped to the whole show for this
            // bulk action.
            await PlaylistCleanup.removeAllFromManualPlaylists(forShowId: showId, playlistClient: playlistClient)
            await syncEngine?.syncNow()
        } catch {
            if !Task.isCancelled {
                markAllPlayedError = "Something went wrong while marking episodes played. Please try again."
            }
        }

        isMarkingAllPlayed = false
    }

    private func refreshStatuses() {
        let episodeIds = Set(episodes.map(\.id))
        let (statuses, positions, archived) = EpisodeStatus.statusAndPositionMaps(for: episodeIds, in: modelContext)
        statusByEpisodeId = statuses
        positionSecondsByEpisodeId = positions
        archivedEpisodeIds = archived
        downloadStatusByEpisodeId = DownloadStatus.statusMap(for: episodeIds, in: modelContext)
    }

    private func restoreAutoPlayed(episodeId: String) async {
        // Derive the badge directly from the returned record rather than refreshStatuses() — that
        // re-fetches every record through this view's own ModelContext, a different instance than
        // the one the write just saved through (same hazard EpisodeDetailView.persist() avoids).
        guard let restored = await syncEngine?.restoreAutoPlayed(episodeId: episodeId) else { return }
        statusByEpisodeId[episodeId] = EpisodeStatus(record: restored)
        positionSecondsByEpisodeId[episodeId] = restored.positionSeconds
        archivedEpisodeIds.remove(episodeId)
        CatalogCache.recordEpisodeStateChange(
            episodeId: episodeId, showId: restored.showId, completed: restored.completed,
            positionSeconds: restored.positionSeconds, in: modelContext)
    }

    private func toggleCompleted(episode: Episode) async {
        guard let syncEngine else { return }
        let episodeId = episode.id
        let currentStatus = statusByEpisodeId[episodeId] ?? .new
        let shouldComplete = currentStatus != .played
        let positionSeconds = shouldComplete ? Int(episode.duration ?? 0) : (positionSecondsByEpisodeId[episodeId] ?? 0)

        do {
            try await syncEngine.write { context in
                let descriptor = FetchDescriptor<EpisodeStateRecord>(predicate: #Predicate { $0.id == episodeId })
                if let existing = try context.fetch(descriptor).first {
                    existing.showId = showId
                    existing.positionSeconds = positionSeconds
                    existing.completed = shouldComplete
                    existing.updatedAt = Date()
                    existing.autoPlayed = false
                    existing.isDirty = true
                } else {
                    context.insert(EpisodeStateRecord(
                        id: episodeId, showId: showId, positionSeconds: positionSeconds,
                        completed: shouldComplete, updatedAt: Date(), isDirty: true))
                }
            }
            let updated = EpisodeStateRecord(
                id: episodeId, showId: showId, positionSeconds: positionSeconds,
                completed: shouldComplete, updatedAt: Date())
            statusByEpisodeId[episodeId] = EpisodeStatus(record: updated)
            positionSecondsByEpisodeId[episodeId] = updated.positionSeconds
            CatalogCache.recordEpisodeStateChange(
                episodeId: episodeId, showId: showId, completed: shouldComplete,
                positionSeconds: positionSeconds, in: modelContext)
            // #532: swipe-to-mark-played bypassed EpisodeDetailView.persist()'s auto-delete-
            // after-played check entirely, leaving downloads stranded. Shares the same rule
            // (DownloadCleanup.deleteIfAutoDeleteEligible) so both paths stay in sync.
            if DownloadCleanup.deleteIfAutoDeleteEligible(
                episodeId: episodeId, completed: shouldComplete, autoDeleteRule: autoDeleteRule, in: modelContext
            ) {
                downloadStatusByEpisodeId[episodeId] = nil
            }
            // #569: swipe-to-mark-played bypassed EpisodeDetailView.persist()'s playlist-removal
            // rule too — shares the same PlaylistCleanup entry point so both paths stay in sync.
            await PlaylistCleanup.removeFromManualPlaylists(
                episodeId: episodeId, completed: shouldComplete, playlistClient: playlistClient)
        } catch {
            assertionFailure("Failed to toggle episode completion: \(episodeId): \(error)")
        }
    }

    private var filterAndSortControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(EpisodeFilter.allCases, id: \.self) { filter in
                        Button(filter.label) {
                            selectedFilter = filter
                        }
                        .buttonStyle(.bordered)
                        .tint(selectedFilter == filter ? .accentColor : .secondary)
                    }

                    Button("Downloaded") {}
                        .buttonStyle(.bordered)
                        .tint(.secondary)
                        .disabled(true)
                        .opacity(0.6)
                }
            }

            Picker("Sort", selection: $selectedSort) {
                ForEach(EpisodeSortOrder.allCases, id: \.self) { order in
                    Text(order.label).tag(order)
                }
            }
            .pickerStyle(.menu)
        }
        .listRowSeparator(.hidden)
    }
}

private struct ShowHeader: View {
    let show: Show
    let isSubscribed: Bool
    let isSubscriptionBusy: Bool
    let subscriptionError: String?
    let onSubscribeTapped: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 16) {
                AsyncImage(url: show.artworkUrl.flatMap(URL.init)) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.secondary.opacity(0.2)
                }
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 4) {
                    Text(show.title)
                        .font(.title3)
                        .bold()
                    Text(show.author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if !show.categories.isEmpty {
                        Text(show.categories.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let description = show.description, !description.isEmpty {
                        Text(description)
                            .font(.footnote)
                            .padding(.top, 4)
                    }
                }
            }

            // Only the "Subscribe" affordance lives in the header; "Unsubscribe" moves into the
            // ⋯ menu (see the toolbar Menu above) as a destructive action.
            if !isSubscribed {
                Button(action: onSubscribeTapped) {
                    if isSubscriptionBusy {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Subscribe")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .tint(.accentColor)
                .disabled(isSubscriptionBusy)
            }

            if let subscriptionError {
                Text(subscriptionError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct EpisodeRow: View {
    let episode: Episode
    let artworkUrl: String?
    let status: EpisodeStatus
    let downloadStatus: DownloadStatus?
    let progressFraction: Double?
    let onPlay: () -> Void
    let onRestore: () -> Void
    let onDownloadDidFinish: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: artworkUrl.flatMap(URL.init)) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.secondary.opacity(0.2)
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(episode.title)
                    .font(.body)
                    .lineLimit(2)

                HStack(spacing: 4) {
                    if let publishedAt = episode.publishedAt {
                        Text(publishedAt.formatted(date: .abbreviated, time: .omitted))
                    }
                    if episode.publishedAt != nil && episode.duration != nil {
                        Text("·")
                    }
                    if let duration = episode.duration {
                        Text(EpisodeFormatting.formatDuration(duration))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let progressFraction {
                    ProgressView(value: progressFraction)
                        .tint(.orange)
                }
            }

            Spacer()

            // A plain Button (not NavigationLink, unlike the row itself) — List's UIKit-backed row
            // hosting reliably gives this its own tap target separate from the row (same as
            // DownloadButton below), so tapping it plays the episode instead of just opening it.
            // A nested NavigationLink here would work the same way for taps, but List also gives
            // it its own disclosure chevron — a confusing second one next to the row's own.
            Button(action: onPlay) {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play episode")

            VStack(alignment: .trailing, spacing: 6) {
                if status == .autoPlayed {
                    StatusBadgeWithRestore(status: status, onRestore: onRestore)
                } else {
                    StatusBadge(status: status)
                }
                DownloadButton(episode: episode, status: downloadStatus, onDidFinish: onDownloadDidFinish)
            }
        }
    }
}

#Preview {
    NavigationStack {
        ShowDetailView(showId: "preview-show")
    }
}
