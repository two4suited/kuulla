import SwiftData
import SwiftUI

// Dedicated screen for managing offline storage — for users who want to see/clear their
// downloads without hunting through individual shows. Only lists .complete records: an
// in-progress or failed download isn't yet a "downloaded episode" a user can manage here, and
// row-level start/cancel affordances belong to the episode list screens (#176), not this one.
struct DownloadsView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var records: [DownloadedEpisodeRecord] = []
    @State private var episodesById: [String: Episode] = [:]
    @State private var deleteError: String?

    private let catalogClient = PodcastCatalogClient()

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
                if !records.isEmpty {
                    Button("Delete All", role: .destructive) {
                        deleteAll()
                    }
                }
            }
        }
        .task {
            load()
            await loadEpisodeMetadata()
        }
    }

    fileprivate static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private func load() {
        let completeStatus = DownloadStatus.complete
        let descriptor = FetchDescriptor<DownloadedEpisodeRecord>(
            predicate: #Predicate { $0.status == completeStatus },
            sortBy: [SortDescriptor(\.downloadedAt, order: .reverse)]
        )
        records = (try? modelContext.fetch(descriptor)) ?? []
    }

    // Best-effort: episode titles/artwork are a display nicety fetched from the catalog, not
    // something stored on DownloadedEpisodeRecord itself (#174's schema is deliberately minimal —
    // just enough to locate/manage the file). A fetch failure leaves that row showing its
    // fallback rather than blocking the rest of the list.
    private func loadEpisodeMetadata() async {
        await withTaskGroup(of: (String, Episode?).self) { group in
            for record in records {
                group.addTask {
                    let episode = try? await catalogClient.getEpisode(showId: record.showId, episodeId: record.id)
                    return (record.id, episode ?? nil)
                }
            }
            for await (id, episode) in group {
                guard let episode else { continue }
                episodesById[id] = episode
            }
        }
    }

    private func deleteRecords(at offsets: IndexSet) {
        deleteError = nil
        guard DownloadCleanup.delete(offsets.map { records[$0] }, from: modelContext) else {
            deleteError = "Something went wrong while deleting. Please try again."
            return
        }
        records.remove(atOffsets: offsets)
    }

    private func deleteAll() {
        deleteError = nil
        guard DownloadCleanup.delete(records, from: modelContext) else {
            deleteError = "Something went wrong while deleting. Please try again."
            return
        }
        records = []
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
    // UI and the store would silently disagree until the next reload.
    @discardableResult
    static func delete(_ records: [DownloadedEpisodeRecord], from context: ModelContext) -> Bool {
        for record in records {
            if !record.localFilePath.isEmpty,
               let fileURL = DownloadManager.downloadsDirectory()?.appendingPathComponent(record.localFilePath) {
                try? FileManager.default.removeItem(at: fileURL)
            }
            context.delete(record)
        }
        do {
            try context.save()
            return true
        } catch {
            return false
        }
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
