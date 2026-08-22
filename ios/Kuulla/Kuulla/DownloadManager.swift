import Foundation
import Observation
import SwiftData

// Downloads an episode's audio to disk using a background URLSession, so the transfer survives
// app suspension/termination (mirrors AudioPlayer's @Observable singleton pattern — one shared
// instance so download state/progress is visible from any screen without re-wiring per view).
@Observable
final class DownloadManager: NSObject {
    static let shared = DownloadManager()

    // 0...1 per episode id while a download is in flight; absent once it completes, fails, or is
    // cancelled — UI reads this to drive a progress ring (#176) and `nil`/missing means "not
    // currently downloading" rather than "0% done".
    private(set) var progress: [String: Double] = [:]

    private var modelContainer: ModelContainer?
    private var session: URLSession!
    // Guards episodeIdsByTaskIdentifier specifically: didFinishDownloadingTo must read it
    // synchronously on URLSession's background delegate queue (the downloaded file is deleted
    // the moment that method returns, so the lookup can't be deferred to a main-queue hop like
    // the other delegate callbacks below), while startDownload/didCompleteWithError write it from
    // the main queue — plain Dictionary access across those two queues would be a data race.
    private let taskMapLock = NSLock()
    private var episodeIdsByTaskIdentifier: [Int: String] = [:]
    private var tasksByEpisodeId: [String: URLSessionDownloadTask] = [:]
    // Set by AppDelegate.application(_:handleEventsForBackgroundURLSession:completionHandler:)
    // when the system relaunches the app to deliver background session events; called once this
    // session's delegate has finished processing all of them, per Apple's documented contract.
    private var backgroundCompletionHandler: (() -> Void)?

    private convenience override init() {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        self.init(configuration: configuration)
    }

    // Test-only seam: production always goes through the background-session convenience init
    // above, but a plain (non-background) configuration with a mocked protocol class lets tests
    // exercise startDownload/cancelDownload and the URLSessionDownloadDelegate callbacks without
    // touching the real network or the OS's background-transfer daemon.
    init(configuration: URLSessionConfiguration) {
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    static let sessionIdentifier = "com.kuulla.app.download"

    // Must be called once from KuullaApp.init, before any download is started — mirrors
    // SyncEngine's registerBackgroundTask() early-wiring requirement, since downloads started
    // before this is set would have nowhere to persist their DownloadedEpisodeRecord.
    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        backgroundCompletionHandler = handler
    }

    func startDownload(episode: Episode) {
        guard let modelContainer, let url = URL(string: episode.audioUrl) else { return }
        guard tasksByEpisodeId[episode.id] == nil else { return }

        let context = ModelContext(modelContainer)
        upsertRecord(episodeId: episode.id, showId: episode.showId, status: .downloading, in: context)

        let task = session.downloadTask(with: url)
        taskMapLock.withLock { episodeIdsByTaskIdentifier[task.taskIdentifier] = episode.id }
        tasksByEpisodeId[episode.id] = task
        progress[episode.id] = 0
        task.resume()
    }

    func cancelDownload(episodeId: String) {
        tasksByEpisodeId[episodeId]?.cancel()
        tasksByEpisodeId[episodeId] = nil
        progress[episodeId] = nil

        guard let modelContainer else { return }
        let context = ModelContext(modelContainer)
        deleteRecord(episodeId: episodeId, in: context)
    }

    private func upsertRecord(episodeId: String, showId: String, status: DownloadStatus, in context: ModelContext) {
        let descriptor = FetchDescriptor<DownloadedEpisodeRecord>(predicate: #Predicate { $0.id == episodeId })
        if let existing = try? context.fetch(descriptor).first {
            existing.status = status
        } else {
            context.insert(DownloadedEpisodeRecord(
                id: episodeId, showId: showId, localFilePath: "", fileSizeBytes: 0,
                downloadedAt: Date(), status: status))
        }
        try? context.save()
    }

    private func deleteRecord(episodeId: String, in context: ModelContext) {
        let descriptor = FetchDescriptor<DownloadedEpisodeRecord>(predicate: #Predicate { $0.id == episodeId })
        guard let existing = try? context.fetch(descriptor).first else { return }
        if !existing.localFilePath.isEmpty, let fileURL = Self.downloadsDirectory()?.appendingPathComponent(existing.localFilePath) {
            try? FileManager.default.removeItem(at: fileURL)
        }
        context.delete(existing)
        try? context.save()
    }

    // The app-container-relative directory downloaded episode files live in — Application
    // Support rather than Documents, since downloads aren't user-visible/iTunes-file-sharing
    // content and shouldn't be included in an iCloud backup of user documents.
    static func downloadsDirectory() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = base.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

// URLSession invokes its delegate on the background queue passed to init (delegateQueue: nil
// creates one). Every callback below either reads episodeIdsByTaskIdentifier through
// taskMapLock (safe to do synchronously, off main) or hops onto the main queue before touching
// tasksByEpisodeId/progress/SwiftData — never both unguarded, which would race against
// startDownload/cancelDownload's direct, main-thread mutation of the same state.
extension DownloadManager: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        let episodeId = taskMapLock.withLock { episodeIdsByTaskIdentifier[downloadTask.taskIdentifier] }
        DispatchQueue.main.async { [weak self] in
            guard let self, let episodeId, totalBytesExpectedToWrite > 0 else { return }
            self.progress[episodeId] = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        }
    }

    // Fires with the downloaded file at a temporary location that's deleted the moment this
    // method returns — must synchronously move it to a stable location before returning, not
    // just record its path. `didFinishDownloadingTo` alone isn't handed a dispatch-safe window
    // (the file is gone once this method returns), so the move itself happens synchronously here
    // and only the SwiftData/state bookkeeping hops to main.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let directory = Self.downloadsDirectory() else { return }
        let episodeId = taskMapLock.withLock { episodeIdsByTaskIdentifier[downloadTask.taskIdentifier] }
        let filename = "\(episodeId ?? UUID().uuidString).\(downloadTask.response?.suggestedFilename.map { ($0 as NSString).pathExtension } ?? "mp3")"
        let destination = directory.appendingPathComponent(filename)

        let fileSizeBytes: Int
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
            fileSizeBytes = (attributes?[.size] as? Int) ?? 0
        } catch {
            DispatchQueue.main.async { [weak self] in
                guard let self, let episodeId, let modelContainer = self.modelContainer else { return }
                self.markFailed(episodeId: episodeId, modelContainer: modelContainer)
            }
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, let episodeId, let modelContainer = self.modelContainer else { return }
            let context = ModelContext(modelContainer)
            let descriptor = FetchDescriptor<DownloadedEpisodeRecord>(predicate: #Predicate { $0.id == episodeId })
            if let record = try? context.fetch(descriptor).first {
                record.localFilePath = filename
                record.fileSizeBytes = fileSizeBytes
                record.downloadedAt = Date()
                record.status = .complete
                try? context.save()
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let episodeId = taskMapLock.withLock({ episodeIdsByTaskIdentifier.removeValue(forKey: task.taskIdentifier) }) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Only act if this episode's tracking is still pointing at *this* task — a cancel
            // immediately followed by a retry replaces tasksByEpisodeId[episodeId] with a new
            // task before the old, now-cancelled task's completion callback reaches here; acting
            // on it regardless would wipe out the new download's task/progress entry (or mark
            // its freshly-started record .failed) out from under it.
            guard self.tasksByEpisodeId[episodeId] === task else { return }
            self.tasksByEpisodeId[episodeId] = nil
            self.progress[episodeId] = nil

            // A cancelled download (cancelDownload already deleted the record) isn't a failure to
            // record — only mark .failed when the transfer itself broke.
            guard let error, (error as NSError).code != NSURLErrorCancelled, let modelContainer = self.modelContainer else { return }
            self.markFailed(episodeId: episodeId, modelContainer: modelContainer)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            self?.backgroundCompletionHandler?()
            self?.backgroundCompletionHandler = nil
        }
    }

    private func markFailed(episodeId: String, modelContainer: ModelContainer) {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<DownloadedEpisodeRecord>(predicate: #Predicate { $0.id == episodeId })
        guard let record = try? context.fetch(descriptor).first else { return }
        record.status = .failed
        try? context.save()
    }
}
