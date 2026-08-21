import SwiftData
import SwiftUI

struct ShowDetailView: View {
    let showId: String

    @Environment(\.episodeSyncEngine) private var syncEngine
    @Environment(\.modelContext) private var modelContext

    @State private var show: Show?
    @State private var isLoadingShow = false
    @State private var showError: String?
    @State private var episodes: [Episode] = []
    @State private var statusByEpisodeId: [String: EpisodeStatus] = [:]
    @State private var positionSecondsByEpisodeId: [String: Int] = [:]
    @State private var archivedEpisodeIds: Set<String> = []
    @State private var selectedFilter: EpisodeFilter = .all
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

    private let catalogClient = PodcastCatalogClient()
    private let subscriptionClient = SubscriptionClient()

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
                                // Only in-progress episodes get a bar — a played episode persists
                                // positionSeconds at the full duration, which would otherwise also
                                // satisfy EpisodeProgress.fraction's guards and render a (stale,
                                // misleading) near-full bar for an episode that's already done.
                                progressFraction: status == .inProgress
                                    ? EpisodeProgress.fraction(
                                        positionSeconds: positionSecondsByEpisodeId[episode.id] ?? 0,
                                        duration: episode.duration)
                                    : nil,
                                onRestore: { Task { await restoreAutoPlayed(episodeId: episode.id) } },
                                onToggleCompleted: { Task { await toggleCompleted(episode: episode) } })
                        }
                        .accessibilityIdentifier("episode-row")
                        .swipeActions(edge: .trailing) {
                            Button {
                                addToPlaylistEpisode = episode
                            } label: {
                                Label("Add to Playlist", systemImage: "text.badge.plus")
                            }
                            .tint(.blue)
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
                Button {
                    isShowingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Podcast settings")
                .disabled(show == nil)
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            ShowSettingsSheet(showId: showId, showTitle: show?.title ?? "Show")
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
        selectedFilter = .all
        selectedSort = .newestFirst
        continuationToken = nil
        episodeError = nil
        isLoadingEpisodes = false
        isSubscribed = false
        isSubscriptionBusy = false
        subscriptionError = nil
        hasToggledSubscription = false

        isLoadingShow = true
        do {
            show = try await catalogClient.getShow(id: showId)
        } catch {
            if !Task.isCancelled {
                showError = "Something went wrong while loading this show. Please try again."
            }
        }
        isLoadingShow = false

        if show != nil {
            await loadMoreEpisodes()
            await loadSubscriptionStatus()
        }
    }

    private func loadSubscriptionStatus() async {
        do {
            let subscriptions = try await subscriptionClient.getSubscriptions()
            guard !Task.isCancelled, !hasToggledSubscription else { return }
            isSubscribed = subscriptions.contains { $0.showId == showId }
        } catch {
            // Not authenticated or the call failed; leave the subscribe button in its default state.
        }
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
            } else {
                _ = try await subscriptionClient.subscribe(showId: showId)
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
            let page = try await catalogClient.getEpisodes(showId: showId, continuationToken: continuationToken)
            episodes.append(contentsOf: page.items)
            continuationToken = page.continuationToken
            refreshStatuses()
        } catch {
            if !Task.isCancelled {
                episodeError = "Something went wrong while loading episodes. Please try again."
            }
        }

        isLoadingEpisodes = false
    }

    private var displayedEpisodes: [Episode] {
        EpisodeListFilter.apply(
            episodes: episodes, statuses: statusByEpisodeId, filter: selectedFilter, sort: selectedSort,
            archived: archivedEpisodeIds)
    }

    private func refreshStatuses() {
        let (statuses, positions, archived) = EpisodeStatus.statusAndPositionMaps(
            for: Set(episodes.map(\.id)), in: modelContext)
        statusByEpisodeId = statuses
        positionSecondsByEpisodeId = positions
        archivedEpisodeIds = archived
    }

    private func restoreAutoPlayed(episodeId: String) async {
        // Derive the badge directly from the returned record rather than refreshStatuses() — that
        // re-fetches every record through this view's own ModelContext, a different instance than
        // the one the write just saved through (same hazard EpisodeDetailView.persist() avoids).
        guard let restored = await syncEngine?.restoreAutoPlayed(episodeId: episodeId) else { return }
        statusByEpisodeId[episodeId] = EpisodeStatus(record: restored)
        positionSecondsByEpisodeId[episodeId] = restored.positionSeconds
        archivedEpisodeIds.remove(episodeId)
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

            Button(action: onSubscribeTapped) {
                if isSubscriptionBusy {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text(isSubscribed ? "Unsubscribe" : "Subscribe")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .tint(isSubscribed ? .red : .accentColor)
            .disabled(isSubscriptionBusy)

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
    let progressFraction: Double?
    let onRestore: () -> Void
    let onToggleCompleted: () -> Void

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

            VStack(alignment: .trailing, spacing: 6) {
                if status == .autoPlayed {
                    StatusBadgeWithRestore(status: status, onRestore: onRestore)
                } else {
                    StatusBadge(status: status)
                    Button(status == .played ? "Mark as Unplayed" : "Mark as Played", action: onToggleCompleted)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        ShowDetailView(showId: "preview-show")
    }
}
