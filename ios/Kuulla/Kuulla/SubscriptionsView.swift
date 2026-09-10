import SwiftData
import SwiftUI

struct SubscriptionsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.settingsSyncEngine) private var settingsSyncEngine
    @Environment(\.catalogRefresh) private var catalogRefresh

    @State private var subscriptions: [Subscription] = []
    @State private var unplayedCounts: [String: UnplayedCounts.Count] = [:]
    @State private var inProgressShowIds: Set<String> = []
    @State private var episodeStateLoaded = false
    // Stays false only until the first (synchronous) read of the local catalog cache lands.
    @State private var hasLoaded = false
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
            } else if !hasLoaded {
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
            // Local-only paint (#488) — see LibraryView. Refresh is cold launch / pull-to-
            // refresh / Settings → "Sync Now".
            await loadSortOrder()
            readLocalSubscriptions()
        }
        .refreshable {
            await catalogRefresh?.refreshAll()
            await loadSortOrder()
            readLocalSubscriptions()
        }
        .onAppear {
            readLocalSubscriptions()
        }
        .onChange(of: catalogRefresh?.isRefreshing) { _, _ in
            // Reflect a cold-launch or Settings "Sync Now" refresh landing while this screen
            // is already on-screen.
            readLocalSubscriptions()
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

    // Locally-synced settings mirror rather than GET /api/settings (#488) — see LibraryView.
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

    // Synchronous paint from the on-device catalog cache (#488) — no network.
    private func readLocalSubscriptions() {
        subscriptions = sortedSubscriptions(
            CatalogCache.subscriptions(in: modelContext), by: sortOrder, manualOrder: manualOrder)
        unplayedCounts = CatalogCache.unplayedCounts(in: modelContext)
        inProgressShowIds = CatalogCache.inProgressShowIds(in: modelContext)
        episodeStateLoaded = true
        hasLoaded = true
        errorMessage = nil
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
