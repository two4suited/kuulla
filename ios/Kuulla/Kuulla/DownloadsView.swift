import SwiftData
import SwiftUI

// Dedicated screen for managing offline storage — for users who want to see/clear their
// downloads without hunting through individual shows. Only lists .complete records: an
// in-progress or failed download isn't yet a "downloaded episode" a user can manage here, and
// row-level start/cancel affordances belong to the episode list screens (#176), not this one.
struct DownloadsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.editMode) private var editMode
    // @Query (rather than a one-shot fetch in .task) so a download that finishes while this
    // screen is already on screen shows up without a relaunch — SwiftData re-runs the query
    // when DownloadManager's background-session callback saves the .complete record on its own
    // ModelContext, and likewise when a download is deleted from an episode screen (#517).
    // Status is filtered in Swift, not the #Predicate, to sidestep SwiftData's flaky enum
    // comparison in compiled predicates.
    @Query(sort: \DownloadedEpisodeRecord.downloadedAt, order: .reverse)
    private var allRecords: [DownloadedEpisodeRecord]
    @State private var episodesById: [String: Episode] = [:]
    // Show artwork keyed by showId, read from the on-device catalog cache (no artwork URL is
    // stored on DownloadedEpisodeRecord itself — #535). Nil for a show that isn't cached.
    @State private var artworkUrlByShowId: [String: URL] = [:]
    @State private var deleteError: String?

    private let catalogClient = PodcastCatalogClient()

    private var records: [DownloadedEpisodeRecord] {
        allRecords.filter { $0.status == .complete }
    }

    private var totalBytes: Int {
        DownloadCleanup.totalBytes(for: records)
    }

    var body: some View {
        List {
            if records.isEmpty {
                Text("No downloaded episodes yet.")
                    .foregroundStyle(.secondary)
            } else {
                Section {
                    ForEach(records) { record in
                        DownloadRow(
                            record: record,
                            episode: episodesById[record.id],
                            artworkUrl: artworkUrlByShowId[record.showId])
                    }
                    .onDelete { offsets in
                        deleteRecords(at: offsets)
                    }
                } header: {
                    Text(Self.byteCountFormatter.string(fromByteCount: Int64(totalBytes)))
                }
            }

            if let deleteError {
                Text(deleteError)
                    .foregroundStyle(.red)
            }
        }
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if records.count > 1 {
                    EditButton()
                }
            }
            ToolbarItem(placement: .bottomBar) {
                if !records.isEmpty, editMode?.wrappedValue.isEditing == true {
                    Button("Delete All", role: .destructive) {
                        deleteAll()
                    }
                }
            }
        }
        .task(id: records.map(\.id)) {
            loadArtwork()
            await loadEpisodeMetadata()
        }
    }

    fileprivate static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    // Show artwork is read straight from the on-device catalog cache — a synchronous SwiftData
    // read, no network. A show that was never cached (or whose cache was cleared) simply has no
    // thumbnail here, matching the best-effort stance of the episode-title lookup below (#535).
    private func loadArtwork() {
        for showId in Set(records.map(\.showId)) where artworkUrlByShowId[showId] == nil {
            if let urlString = CatalogCache.show(id: showId, in: modelContext)?.artworkUrl,
               let url = URL(string: urlString) {
                artworkUrlByShowId[showId] = url
            }
        }
    }

    // Best-effort: episode titles are a display nicety fetched from the catalog, not something
    // stored on DownloadedEpisodeRecord itself (#174's schema is deliberately minimal — just
    // enough to locate/manage the file). A fetch failure leaves that row showing its fallback
    // rather than blocking the rest of the list. Bounded to a small concurrency window rather
    // than firing one request per download at once — a large downloads list shouldn't
    // burst-request the API for every row simultaneously. Looks up by plain (id, showId) pairs,
    // not the DownloadedEpisodeRecord itself, so no @Model instance crosses into a child task.
    private func loadEpisodeMetadata() async {
        // Only fetch rows we don't already have metadata for — this runs again every time a new
        // download appears, and re-requesting every existing row's episode each time would
        // burst the API on an unrelated change.
        let lookups = records
            .filter { episodesById[$0.id] == nil }
            .map { (id: $0.id, showId: $0.showId) }
        let maxConcurrentRequests = 4
        var nextIndex = 0

        await withTaskGroup(of: (String, Episode?).self) { group in
            func addTaskIfAvailable() {
                guard nextIndex < lookups.count else { return }
                let lookup = lookups[nextIndex]
                nextIndex += 1
                group.addTask {
                    let episode = try? await self.catalogClient.getEpisode(showId: lookup.showId, episodeId: lookup.id)
                    return (lookup.id, episode ?? nil)
                }
            }

            for _ in 0..<min(maxConcurrentRequests, lookups.count) {
                addTaskIfAvailable()
            }
            for await (id, episode) in group {
                if let episode {
                    episodesById[id] = episode
                }
                addTaskIfAvailable()
            }
        }
    }

    // No manual list mutation on success — @Query re-runs off the same ModelContext save and
    // drops the deleted rows on its own.
    private func deleteRecords(at offsets: IndexSet) {
        deleteError = nil
        let current = records
        guard DownloadCleanup.delete(offsets.map { current[$0] }, from: modelContext) else {
            deleteError = "Something went wrong while deleting. Please try again."
            return
        }
    }

    private func deleteAll() {
        deleteError = nil
        guard DownloadCleanup.delete(records, from: modelContext) else {
            deleteError = "Something went wrong while deleting. Please try again."
            return
        }
    }
}

// Pulled out of DownloadsView so the delete-and-clean-up-the-file behavior is unit-testable
// against a real in-memory ModelContainer and real temp files, the same way DownloadManager's
// own SwiftData/FileManager interactions are tested — a SwiftUI View's @State can't be driven
// directly from XCTest.
enum DownloadCleanup {
    static func totalBytes(for records: [DownloadedEpisodeRecord]) -> Int {
        records.reduce(0) { $0 + $1.fileSizeBytes }
    }

    // Returns false if the ModelContext failed to save the deletion — the caller must not treat
    // the records as gone in that case (e.g. by removing them from its own @State list), or the
    // UI and the store would silently disagree until the next reload. The SwiftData delete is
    // saved *before* any file is removed from disk: if the save fails, every file stays in
    // place, so a retry has something to act on instead of a record whose file already vanished.
    @discardableResult
    static func delete(_ records: [DownloadedEpisodeRecord], from context: ModelContext) -> Bool {
        for record in records {
            context.delete(record)
        }
        do {
            try context.save()
        } catch {
            return false
        }
        for record in records {
            removeFile(for: record)
        }
        return true
    }

    // #532: shared entry point for the "auto-delete this episode's download once it's marked
    // played" policy, so every place that can change an episode's completed state — natural
    // finish, the manual toggle in EpisodeDetailView, swipe-to-mark-played in ShowDetailView —
    // goes through the same rule check instead of each reimplementing (or forgetting) it.
    @discardableResult
    static func deleteIfAutoDeleteEligible(
        episodeId: String, completed: Bool, autoDeleteRule: AutoDeleteRule, in context: ModelContext
    ) -> Bool {
        guard shouldAutoDelete(completed: completed, autoDeleteRule: autoDeleteRule) else { return false }
        let descriptor = FetchDescriptor<DownloadedEpisodeRecord>(predicate: #Predicate { $0.id == episodeId })
        guard let record = try? context.fetch(descriptor).first, record.status == .complete else { return false }
        return delete([record], from: context)
    }

    // Bulk counterpart for "mark all played" (#532): that action marks a show's *entire* back
    // catalogue played server-side regardless of how much of it is paged into the caller's
    // @State episode list, so cleanup must be scoped the same way — a single fetch of every
    // downloaded episode for the show, not a loop over whatever page happens to be loaded (which
    // would silently strand downloads on not-yet-paginated episodes). Returns the ids actually
    // deleted so callers can clear their own per-episode UI state.
    @discardableResult
    static func deleteAllEligible(
        forShowId showId: String, autoDeleteRule: AutoDeleteRule, in context: ModelContext
    ) -> [String] {
        guard shouldAutoDelete(completed: true, autoDeleteRule: autoDeleteRule) else { return [] }
        let descriptor = FetchDescriptor<DownloadedEpisodeRecord>(predicate: #Predicate { $0.showId == showId })
        let records = ((try? context.fetch(descriptor)) ?? []).filter { $0.status == .complete }
        guard !records.isEmpty, delete(records, from: context) else { return [] }
        return records.map(\.id)
    }

    // Pulled out as a pure function for testability, mirroring resolvedPlaybackURL's pattern.
    nonisolated static func shouldAutoDelete(completed: Bool, autoDeleteRule: AutoDeleteRule) -> Bool {
        completed && autoDeleteRule == .afterPlayed
    }

    private static func removeFile(for record: DownloadedEpisodeRecord) {
        guard !record.localFilePath.isEmpty, let directory = DownloadManager.downloadsDirectory() else { return }
        let fileURL = directory.appendingPathComponent(record.localFilePath)
        // A corrupted or (however implausibly) malicious localFilePath containing path
        // components like "../../" could otherwise resolve outside the sandboxed downloads
        // directory — never remove anything that doesn't standardize to a path still inside it.
        let standardizedFile = fileURL.standardizedFileURL.path
        let standardizedDirectory = directory.standardizedFileURL.path
        guard standardizedFile.hasPrefix(standardizedDirectory + "/") else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}

private struct DownloadRow: View {
    let record: DownloadedEpisodeRecord
    let episode: Episode?
    let artworkUrl: URL?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ShowArtworkThumbnail(url: artworkUrl)

            VStack(alignment: .leading, spacing: 2) {
                Text(episode?.title ?? "Episode \(record.id)")
                    .lineLimit(2)
                Text(DownloadsView.byteCountFormatter.string(fromByteCount: Int64(record.fileSizeBytes)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// Small square show-artwork thumbnail, mirroring FeedView's treatment for visual consistency
// across episode lists (#535). A missing or still-loading URL falls back to a tinted
// placeholder rather than a broken image.
private struct ShowArtworkThumbnail: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            ZStack {
                Color.secondary.opacity(0.2)
                Image(systemName: "mic")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

#Preview {
    NavigationStack {
        DownloadsView()
    }
    .modelContainer(for: DownloadedEpisodeRecord.self, inMemory: true)
}
