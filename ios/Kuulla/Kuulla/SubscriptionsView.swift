import SwiftUI

struct SubscriptionsView: View {
    @State private var subscriptions: [Subscription] = []
    @State private var unplayedCounts: [String: UnplayedCounts.Count] = [:]
    @State private var inProgressShowIds: Set<String> = []
    @State private var episodeStateLoaded = false
    @State private var isLoading = false
    @State private var errorMessage: String?
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
    // Nil until the best-effort episode-state fetch completes, so the grid never hides or
    // re-sinks shows on incomplete data.
    private var activeShowIds: Set<String>? {
        episodeStateLoaded ? Set(unplayedCounts.keys).union(inProgressShowIds) : nil
    }

    private var displayedSubscriptions: [Subscription] {
        sortedSubscriptions(
            subscriptions, by: sortOrder, manualOrder: manualOrder,
            activeShowIds: activeShowIds, hideCaughtUp: hideCaughtUpShows)
    }

    @AppStorage(ShowIconSize.storageKey) private var iconSizeRaw = ShowIconSize.default.rawValue

    private let subscriptionClient = SubscriptionClient()
    private let settingsClient = SettingsClient()

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: ShowIconSize.current(iconSizeRaw).gridMinimum), spacing: 16)]
    }

    var body: some View {
        ScrollView {
            if let sortSaveError {
                Text(sortSaveError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.top)
            }
            if let hideCaughtUpSaveError {
                Text(hideCaughtUpSaveError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.top)
            }
            if let manualSaveError {
                Text(manualSaveError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.top)
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .padding()
            } else if isLoading {
                ProgressView()
                    .padding()
            } else if subscriptions.isEmpty {
                Text("You haven't subscribed to any shows yet.")
                    .foregroundStyle(.secondary)
                    .padding()
            } else if sortOrder == .manual {
                manualReorderList
            } else if displayedSubscriptions.isEmpty {
                Text("You're caught up on every show. Turn off \u{201C}Hide caught-up shows\u{201D} to see them all.")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(displayedSubscriptions) { subscription in
                        NavigationLink(value: CatalogRoute.show(id: subscription.showId)) {
                            SubscriptionTile(
                                subscription: subscription,
                                unplayedCount: unplayedCounts[subscription.showId])
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
        }
        .navigationTitle("Subscriptions")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShowDisplaySettingsMenu(
                    sortOrder: sortOrderBinding,
                    hideCaughtUpShows: hideCaughtUpBinding,
                    isDisabled: subscriptions.isEmpty && errorMessage == nil)
            }
        }
        .task {
            async let subscriptionsTask: Void = loadSubscriptions()
            async let sortTask: Void = loadSortOrder()
            _ = await (subscriptionsTask, sortTask)
        }
        .refreshable {
            await loadSubscriptions()
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

    // Non-scrolling List in the page's ScrollView, held in edit mode so reorder grips always
    // show. Drag to rearrange; each move persists the full showId array (#438).
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
                // On failure roll back the optimistic change and surface an error, matching the
                // web pages — a silently-dropped save would otherwise revert on next launch.
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
            })
    }

    private func loadSortOrder() async {
        guard let settings = try? await settingsClient.getSettings(), !Task.isCancelled else { return }
        sortOrder = settings.subscriptionSortOrder
        manualOrder = settings.subscriptionManualOrder
        hideCaughtUpShows = settings.hideCaughtUpShows
        subscriptions = sortedSubscriptions(subscriptions, by: sortOrder, manualOrder: manualOrder)
    }

    private func loadSubscriptions() async {
        guard !isLoading else { return }

        isLoading = true
        errorMessage = nil

        do {
            let results = sortedSubscriptions(
                try await subscriptionClient.getSubscriptions(), by: sortOrder, manualOrder: manualOrder)
            if !Task.isCancelled {
                subscriptions = results
            }
        } catch {
            if !Task.isCancelled {
                errorMessage = "Something went wrong while loading your subscriptions. Please try again."
            }
        }

        // Always clears the flag, even if cancelled — mirrors LibraryView.loadShows(): the
        // best-effort badge fetch below must run after loading state clears, not only at the end.
        isLoading = false
        guard !Task.isCancelled, errorMessage == nil else { return }

        // Best-effort, run after the grid has already rendered: unplayed badges are supplementary,
        // so a failure here shouldn't hide the already-loaded subscriptions grid behind an error.
        // The same data also drives the caught-up hide/sink, gated on episodeStateLoaded so
        // nothing is hidden until both fetches have actually landed. Fetched concurrently —
        // neither depends on the other.
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

}

private struct SubscriptionTile: View {
    let subscription: Subscription
    let unplayedCount: UnplayedCounts.Count?

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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(subscription.showTitle)
    }
}

#Preview {
    NavigationStack {
        SubscriptionsView()
    }
}
