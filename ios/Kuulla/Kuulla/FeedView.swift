import SwiftData
import SwiftUI

struct FeedView: View {
    @Environment(\.episodeSyncEngine) private var syncEngine
    @Environment(\.modelContext) private var modelContext

    @State private var episodes: [Episode] = []
    @State private var statusByEpisodeId: [String: EpisodeStatus] = [:]
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let subscriptionClient = SubscriptionClient()

    var body: some View {
        // A List (rather than ScrollView + LazyVStack, as before), matching ShowDetailView — its
        // UIKit-backed row hosting reliably separates a nested control's tap target (the Restore
        // button below) from the row's own NavigationLink activation, which a plain LazyVStack
        // does not reliably do.
        List {
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            } else if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if episodes.isEmpty {
                Text("You're all caught up — no new episodes from your subscriptions.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(episodes) { episode in
                    NavigationLink(value: CatalogRoute.episode(showId: episode.showId, episodeId: episode.id)) {
                        FeedEpisodeRow(
                            episode: episode,
                            status: statusByEpisodeId[episode.id] ?? .new,
                            onRestore: { Task { await restoreAutoPlayed(episodeId: episode.id) } })
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Home")
        .task {
            await load()
        }
        .onAppear {
            // Cheap local-only re-derivation (no network) so a badge marked played/in-progress from
            // the detail screen isn't left stale when popping back here — SwiftUI doesn't re-run
            // .task just because a pushed NavigationLink destination was popped.
            refreshStatuses()
        }
        .refreshable {
            await syncEngine?.syncNow()
            await load()
        }
    }

    private func load() async {
        guard !isLoading else { return }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let results = try await subscriptionClient.getNewEpisodes()
                .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
            guard !Task.isCancelled else { return }
            episodes = results
            refreshStatuses()
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = "Something went wrong while loading your new episodes. Please try again."
        }
    }

    private func restoreAutoPlayed(episodeId: String) async {
        // Derive the badge directly from the returned record rather than refreshStatuses() — that
        // re-fetches every record through this view's own ModelContext, a different instance than
        // the one the write just saved through (same hazard EpisodeDetailView.persist() avoids).
        guard let restored = await syncEngine?.restoreAutoPlayed(episodeId: episodeId) else { return }
        statusByEpisodeId[episodeId] = EpisodeStatus(record: restored)
    }

    private func refreshStatuses() {
        statusByEpisodeId = EpisodeStatus.statusMap(for: Set(episodes.map(\.id)), in: modelContext)
    }
}

private struct FeedEpisodeRow: View {
    let episode: Episode
    let status: EpisodeStatus
    let onRestore: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(episode.title)
                    .font(.body)
                    .lineLimit(2)
                    .foregroundStyle(.primary)

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
            }

            Spacer()

            StatusBadgeWithRestore(status: status, onRestore: onRestore)
        }
        .padding()
    }
}

#Preview {
    NavigationStack {
        FeedView()
    }
    .modelContainer(for: EpisodeStateRecord.self, inMemory: true)
}
