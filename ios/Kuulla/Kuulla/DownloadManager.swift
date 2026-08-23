import Foundation
import Network
import Observation
import SwiftData

// Abstracts NWPathMonitor so DownloadManager's Wi-Fi-only gating (#180) is testable without
// depending on the device's real, non-deterministic network state.
protocol NetworkPathObserving {
    func startObserving(onUpdate: @escaping (_ isOnWifi: Bool) -> Void)
}

final class NWPathMonitorAdapter: NetworkPathObserving {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.kuulla.app.download.pathMonitor")

    func startObserving(onUpdate: @escaping (Bool) -> Void) {
        monitor.pathUpdateHandler = { path in onUpdate(path.usesInterfaceType(.wifi)) }
        monitor.start(queue: queue)
    }
}

// Downloads an episode's audio to disk using a background URLSession, so the transfer survives
// app suspension/termination (mirrors AudioPlayer's @Observable singleton pattern — one shared
// instance so download state/progress is visible from any screen without re-wiring per view).
@Observable
final class DownloadManager: NSObject {
    static let shared = DownloadManager()

    // 0...1 per episode id while a download is in flight; absent once it completes, fails, or is
    // cancelled — UI reads this to drive a progress ring (#176) and `nil`/missing means "not
    // currently downloading" rather than "0% done". A queued (Wi-Fi-only, waiting for Wi-Fi)
    // episode has no entry here either — the same "no live progress" DownloadButton fallback
    // (#176) that covers a just-relaunched in-flight download covers "waiting for Wi-Fi" too.
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

    // Requested while off Wi-Fi with LocalSettings.wifiOnlyDownloads on: no URLSessionDownloadTask
    // exists yet for these, so cancelDownload/didCompleteWithError's task-based bookkeeping can't
    // reach them — they're started (moved into tasksByEpisodeId) the moment Wi-Fi returns.
    private var pendingEpisodes: [String: Episode] = [:]
    // In-flight tasks suspended (not cancelled) because Wi-Fi was lost mid-transfer — resumed
    // from where they left off once Wi-Fi returns, rather than restarting from scratch.
    private var pausedEpisodeIds: Set<String> = []
    // Pessimistic default: only LocalSettings.wifiOnlyDownloads == true even looks at this value
    // (the guard is `wifiOnlyDownloads && !isOnWifi`), so defaulting to "not on Wi-Fi" costs
    // nothing when the setting is off, and avoids a download starting over cellular — or a
    // reattached task resuming over cellular — in the brief window before the path observer's
    // first real callback lands when the setting is on.
    private var isOnWifi = false

    private convenience override init() {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        self.init(configuration: configuration)
    }

    // Test-only seam: production always goes through the background-session convenience init
    // above, but a plain (non-background) configuration with a mocked protocol class lets tests
    // exercise startDownload/cancelDownload and the URLSessionDownloadDelegate callbacks without
    // touching the real network or the OS's background-transfer daemon. `pathObserver` is
    // similarly swappable so tests can simulate Wi-Fi/cellular transitions deterministically.
    init(configuration: URLSessionConfiguration, pathObserver: NetworkPathObserving = NWPathMonitorAdapter()) {
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        pathObserver.startObserving { [weak self] isOnWifi in
            DispatchQueue.main.async { self?.handlePathUpdate(isOnWifi: isOnWifi) }
        }
        reattachExistingTasks()
    }

    // pausedEpisodeIds/tasksByEpisodeId are purely in-memory — a task suspended for lack of
    // Wi-Fi (or just genuinely still in flight) survives a process relaunch in the OS's
    // background-transfer daemon, but this object doesn't, so without this the download would be
    // stuck forever: `resumePausedTransfers()` can only resume a task it still knows about, and a
    // fresh instance's tasksByEpisodeId/pausedEpisodeIds start empty. Reconnecting to the same
    // background session identifier hands back the surviving task objects; taskDescription
    // (set in beginTransfer) is how each is matched back to its episode id.
    private func reattachExistingTasks() {
        session.getAllTasks { [weak self] tasks in
            DispatchQueue.main.async {
                guard let self else { return }
                var reattachedEpisodeIds: Set<String> = []
                for case let task as URLSessionDownloadTask in tasks {
                    guard let episodeId = task.taskDescription else { continue }
                    reattachedEpisodeIds.insert(episodeId)
                    self.taskMapLock.withLock { self.episodeIdsByTaskIdentifier[task.taskIdentifier] = episodeId }
                    self.tasksByEpisodeId[episodeId] = task
                    self.progress[episodeId] = 0
                    if LocalSettings.wifiOnlyDownloads && !self.isOnWifi {
                        // Don't resume over cellular just because the task happened to be
                        // running (not suspended-for-Wi-Fi specifically) when the app died —
                        // isOnWifi is unknown until the path observer's first real callback
                        // lands, and pessimistically-false means we wait for it rather than
                        // guess. suspend() on an already-suspended task is a harmless no-op.
                        task.suspend()
                        self.pausedEpisodeIds.insert(episodeId)
                    } else {
                        task.resume()
                    }
                }
                self.failOrphanedDownloadingRecords(reattachedEpisodeIds: reattachedEpisodeIds)
            }
        }
    }

    // A .downloading record with no reattached task and no in-memory pendingEpisodes entry
    // (pendingEpisodes always starts empty on relaunch — it's never persisted) was queued,
    // waiting for Wi-Fi, when the app was terminated. There's no way to resume it automatically:
    // DownloadedEpisodeRecord doesn't carry the episode's audioUrl, only the original caller did,
    // so nothing here can rebuild an Episode to retry with. Marking it .failed — instead of
    // leaving it stuck showing a permanent indeterminate ring (#176) — gives the user a visible,
    // actionable "tap to retry" state instead of silence.
    private func failOrphanedDownloadingRecords(reattachedEpisodeIds: Set<String>) {
        guard let modelContainer else { return }
        let context = ModelContext(modelContainer)
        let downloadingStatus = DownloadStatus.downloading
        let descriptor = FetchDescriptor<DownloadedEpisodeRecord>(predicate: #Predicate { $0.status == downloadingStatus })
        guard let records = try? context.fetch(descriptor) else { return }
        var didChange = false
        for record in records where !reattachedEpisodeIds.contains(record.id) {
            record.status = .failed
            didChange = true
        }
        if didChange {
            try? context.save()
        }
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
        guard let modelContainer, URL(string: episode.audioUrl) != nil else { return }
        guard tasksByEpisodeId[episode.id] == nil, pendingEpisodes[episode.id] == nil else { return }

        let context = ModelContext(modelContainer)
        upsertRecord(episodeId: episode.id, showId: episode.showId, status: .downloading, in: context)

        // Queue rather than start (or silently drop) the transfer when Wi-Fi-only downloads are
        // on and we're not currently on Wi-Fi — beginTransfer runs once handlePathUpdate sees
        // Wi-Fi return. The DownloadedEpisodeRecord above already shows .downloading either way,
        // matching #180's "queued (rather than silently drops)" requirement.
        if LocalSettings.wifiOnlyDownloads && !isOnWifi {
            pendingEpisodes[episode.id] = episode
            return
        }

        beginTransfer(for: episode)
    }

    private func beginTransfer(for episode: Episode) {
        guard let url = URL(string: episode.audioUrl) else { return }
        let task = session.downloadTask(with: url)
        // Lets reattachExistingTasks() match a task recovered after relaunch back to its episode.
        task.taskDescription = episode.id
        taskMapLock.withLock { episodeIdsByTaskIdentifier[task.taskIdentifier] = episode.id }
        tasksByEpisodeId[episode.id] = task
        progress[episode.id] = 0
        task.resume()
    }

    func cancelDownload(episodeId: String) {
        pendingEpisodes[episodeId] = nil
        pausedEpisodeIds.remove(episodeId)
        tasksByEpisodeId[episodeId]?.cancel()
        tasksByEpisodeId[episodeId] = nil
        progress[episodeId] = nil

        guard let modelContainer else { return }
        let context = ModelContext(modelContainer)
        deleteRecord(episodeId: episodeId, in: context)
    }

    // Reacts to a Wi-Fi/cellular transition (only on an actual change — NWPathMonitor-style
    // observers report the current path immediately on start, which would otherwise look like a
    // spurious "transition" the very first time this fires).
    private func handlePathUpdate(isOnWifi: Bool) {
        let wasOnWifi = self.isOnWifi
        self.isOnWifi = isOnWifi
        guard isOnWifi != wasOnWifi else { return }
        applyWifiGating()
    }

    // Call after the user toggles LocalSettings.wifiOnlyDownloads — without this, flipping the
    // setting off while off Wi-Fi would leave already-queued downloads waiting for a network
    // transition that might not come for a long time (same connection type, just a preference
    // change), and flipping it on while off Wi-Fi wouldn't pause an in-flight cellular transfer
    // until the next transition either.
    func wifiOnlyDownloadsSettingChanged() {
        applyWifiGating()
    }

    private func applyWifiGating() {
        if isOnWifi || !LocalSettings.wifiOnlyDownloads {
            resumePausedTransfers()
            startPendingDownloads()
        } else {
            pauseInFlightTransfers()
        }
    }

    private func startPendingDownloads() {
        let episodes = pendingEpisodes
        pendingEpisodes.removeAll()
        for episode in episodes.values {
            beginTransfer(for: episode)
        }
    }

    // Suspends rather than cancels: the transfer resumes from where it left off once Wi-Fi
    // returns, instead of restarting the download (and re-spending the cellular-avoided bytes)
    // from scratch.
    private func pauseInFlightTransfers() {
        for (episodeId, task) in tasksByEpisodeId {
            task.suspend()
            pausedEpisodeIds.insert(episodeId)
        }
    }

    private func resumePausedTransfers() {
        for episodeId in pausedEpisodeIds {
            tasksByEpisodeId[episodeId]?.resume()
        }
        pausedEpisodeIds.removeAll()
    }

    private func upsertRecord(episodeId: String, showId: String, status: DownloadStatus, in context: ModelContext) {
        let descriptor = FetchDescriptor<DownloadedEpisodeRecord>(predicate: #Predicate { $0.id == episodeId })
        if let existing = try? context.fetch(descriptor).first {
            // A re-download (e.g. after the file was evicted, or the user just wants a fresh
            // copy) reuses this record rather than inserting a second one — but its
            // localFilePath/fileSizeBytes still point at the *previous* download's file. Left in
            // place, a later cancelDownload of this new attempt would delete that old, unrelated
            // file (deleteRecord trusts localFilePath), and a reader could briefly see a stale
            // size/path paired with a .downloading status.
            if !existing.localFilePath.isEmpty, let fileURL = Self.downloadsDirectory()?.appendingPathComponent(existing.localFilePath) {
                try? FileManager.default.removeItem(at: fileURL)
            }
            existing.localFilePath = ""
            existing.fileSizeBytes = 0
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
    // content. Storing here doesn't by itself exclude files from an iCloud backup (unlike
    // Caches) — didFinishDownloadingTo sets isExcludedFromBackupKey on each file explicitly,
    // since large, easily-re-downloaded audio shouldn't bloat a user's backup.
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
        // suggestedFilename's extension is empty (not just absent) whenever the response has no
        // extractable extension, which would otherwise leave a trailing "." with nothing after it.
        let rawExtension = downloadTask.response?.suggestedFilename.map { ($0 as NSString).pathExtension } ?? ""
        let fileExtension = rawExtension.isEmpty ? "mp3" : rawExtension
        let filename = "\(episodeId ?? UUID().uuidString).\(fileExtension)"
        var destination = directory.appendingPathComponent(filename)

        let fileSizeBytes: Int
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            var excludedFromBackup = URLResourceValues()
            excludedFromBackup.isExcludedFromBackup = true
            try? destination.setResourceValues(excludedFromBackup)
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
            guard let record = try? context.fetch(descriptor).first else {
                // The record was removed (e.g. a very-late cancel) before this callback landed —
                // nothing left to attach the file to, so don't leave it orphaned on disk.
                try? FileManager.default.removeItem(at: destination)
                return
            }
            record.localFilePath = filename
            record.fileSizeBytes = fileSizeBytes
            record.downloadedAt = Date()
            record.status = .complete
            try? context.save()
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
