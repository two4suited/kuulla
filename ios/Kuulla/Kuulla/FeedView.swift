import SwiftData
import SwiftUI

struct FeedView: View {
    @Environment(\.episodeSyncEngine) private var syncEngine
    @Environment(\.modelContext) private var modelContext

    @State private var episodes: [Episode] = []
    @State private var statusByEpisodeId: [String: EpisodeStatus] = [:]
    @State private var downloadStatusByEpisodeId: [String: DownloadStatus] = [:]
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let subscriptionClient = SubscriptionClient()
    private let settingsClient = SettingsClient()

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
                            downloadStatus: downloadStatusByEpisodeId[episode.id],
                            onRestore: { Task { await restoreAutoPlayed(episodeId: episode.id) } },
                            onDownloadDidFinish: refreshStatuses)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("New Episodes")
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
            // Excludes autoPlayed episodes — they're already marked played by the unlistened-episode
            // limit, so they shouldn't clutter the "New Episodes" list (mirrors NewEpisodes.razor on
            // Web). A restore path for those still exists via ShowDetailView's status filter chips.
            let results = try await subscriptionClient.getNewEpisodes()
                .filter { !$0.autoPlayed }
                .map(\.episode)
                .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
            guard !Task.isCancelled else { return }
            episodes = results
            refreshStatuses()
            await triggerAutoDownloads()
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = "Something went wrong while loading your new episodes. Please try again."
        }
    }

    // #270: no new episode-detection mechanism — this reuses getNewEpisodes(), the same
    // server-side "new episode" signal load() already fetches, rather than inventing a second
    // one. Only considers episodes with no DownloadedEpisodeRecord at all: one that's already
    // .downloading/.complete/.failed was touched by something else (a manual tap, a previous
    // auto-download) and re-triggering it here on every refresh would be at best redundant, at
    // worst a wasted re-download (or silently retrying a .failed one the user hasn't asked to retry).
    private func triggerAutoDownloads() async {
        let candidates = episodes.filter { downloadStatusByEpisodeId[$0.id] == nil }
        guard !candidates.isEmpty else { return }

        let globalDefault = (try? await settingsClient.getSettings())?.autoDownloadNewEpisodes ?? false
        let showOverrides = await fetchShowAutoDownloadOverrides(for: Set(candidates.map(\.showId)))

        for episode in candidates {
            // A show whose settings fetch failed has no key here at all — distinct from a show
            // that was fetched successfully and has no override (present with a nil value).
            // Falling through to globalDefault for a failed fetch would risk silently
            // overriding a user's explicit per-show opt-out (override == false) with a
            // transient network hiccup; skipping this episode for this round instead fails
            // closed, and the next refresh gets another chance to resolve it correctly.
            guard let showOverride = showOverrides[episode.showId] else { continue }
            if Self.shouldAutoDownload(
                downloadStatus: downloadStatusByEpisodeId[episode.id], showOverride: showOverride, globalDefault: globalDefault
            ) {
                DownloadManager.shared.startDownload(episode: episode)
            }
        }
    }

    // Pulled out as a pure function for testability, mirroring the codebase's established
    // pattern (EpisodeDetailView.resolvedPlaybackURL, DownloadButton.effectiveStatus).
    static func shouldAutoDownload(downloadStatus: DownloadStatus?, showOverride: Bool?, globalDefault: Bool) -> Bool {
        guard downloadStatus == nil else { return false }
        return showOverride ?? globalDefault
    }

    // Bounded concurrency (mirroring DownloadsView's episode-metadata fetch) rather than one
    // request per distinct show at once — a user subscribed to many shows with new episodes
    // shouldn't burst-request the API for every one of them simultaneously. A show whose fetch
    // fails is left out of the returned dictionary entirely (not inserted with a nil value) —
    // triggerAutoDownloads relies on that key's absence to distinguish "fetch failed" from
    // "fetched fine, no override" and skip the episode rather than guessing.
    private func fetchShowAutoDownloadOverrides(for showIds: Set<String>) async -> [String: Bool?] {
        var overridesByShowId: [String: Bool?] = [:]
        let maxConcurrentRequests = 4
        var iterator = showIds.makeIterator()

        await withTaskGroup(of: (showId: String, override: Bool?, didFail: Bool).self) { group in
            func addTaskIfAvailable() {
                guard let showId = iterator.next() else { return }
                group.addTask {
                    guard let showSettings = try? await self.settingsClient.getShowSettings(showId: showId) else {
                        return (showId, nil, true)
                    }
                    return (showId, showSettings.autoDownloadNewEpisodes, false)
                }
            }

            for _ in 0..<min(maxConcurrentRequests, showIds.count) {
                addTaskIfAvailable()
            }
            for await result in group {
                if !result.didFail {
                    overridesByShowId[result.showId] = result.override
                }
                addTaskIfAvailable()
            }
        }

        return overridesByShowId
    }

    private func restoreAutoPlayed(episodeId: String) async {
        // Derive the badge directly from the returned record rather than refreshStatuses() — that
        // re-fetches every record through this view's own ModelContext, a different instance than
        // the one the write just saved through (same hazard EpisodeDetailView.persist() avoids).
        guard let restored = await syncEngine?.restoreAutoPlayed(episodeId: episodeId) else { return }
        statusByEpisodeId[episodeId] = EpisodeStatus(record: restored)
    }

    private func refreshStatuses() {
        let episodeIds = Set(episodes.map(\.id))
        statusByEpisodeId = EpisodeStatus.statusMap(for: episodeIds, in: modelContext)
        downloadStatusByEpisodeId = DownloadStatus.statusMap(for: episodeIds, in: modelContext)
    }
}

private struct FeedEpisodeRow: View {
    let episode: Episode
    let status: EpisodeStatus
    let downloadStatus: DownloadStatus?
    let onRestore: () -> Void
    let onDownloadDidFinish: () -> Void

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

            VStack(alignment: .trailing, spacing: 8) {
                StatusBadgeWithRestore(status: status, onRestore: onRestore)
                DownloadButton(episode: episode, status: downloadStatus, onDidFinish: onDownloadDidFinish)
            }
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
