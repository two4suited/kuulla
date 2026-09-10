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
                        DownloadRow(record: record, episode: episodesById[record.id])
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
            await loadEpisodeMetadata()
        }
    }

    fileprivate static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    // Best-effort: episode titles/artwork are a display nicety fetched from the catalog, not
    // something stored on DownloadedEpisodeRecord itself (#174's schema is deliberately minimal —
    // just enough to locate/manage the file). A fetch failure leaves that row showing its
    // fallback rather than blocking the rest of the list. Bounded to a small concurrency window
    // rather than firing one request per download at once — a large downloads list shouldn't
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

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(episode?.title ?? "Episode \(record.id)")
                .lineLimit(2)
            Text(DownloadsView.byteCountFormatter.string(fromByteCount: Int64(record.fileSizeBytes)))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    NavigationStack {
        DownloadsView()
    }
    .modelContainer(for: DownloadedEpisodeRecord.self, inMemory: true)
}
