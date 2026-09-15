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
    // Also guarded by taskMapLock. Tasks whose finished payload didFinishDownloadingTo refused
    // (non-2xx status, a web page instead of audio, or a file move that failed): the record is
    // marked .failed from didCompleteWithError, in the same main-queue block that clears the
    // task's bookkeeping — never from didFinishDownloadingTo's own dispatch, which would let the
    // UI show "tap to retry" a beat before startDownload's in-flight guard would accept the tap.
    private var rejectedTaskIdentifiers: Set<Int> = []
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

    // Retained so its NWPathMonitor keeps running — startObserving's closure only captures
    // onUpdate, not the observer itself, so without this the adapter deinits at the end of
    // init and path updates silently stop (mirrors the AudioPlayer fix, #271).
    private var pathObserver: NetworkPathObserving

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
        self.pathObserver = pathObserver
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.pathObserver.startObserving { [weak self] isOnWifi in
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

    // #689's "latest N episodes" auto-download rule — called by FeedView after starting this
    // round's auto-downloads for a show whose effective limit is non-zero. Evicts by downloadedAt
    // (download recency) rather than the episode's publish date: auto-download only ever
    // triggers off "new episode" notifications, so download order already tracks publish order in
    // practice, and this avoids an extra per-episode metadata fetch just to enforce the cap.
    func enforceEpisodeLimit(showId: String, limit: Int, in context: ModelContext) {
        guard limit > 0 else { return }
        let descriptor = FetchDescriptor<DownloadedEpisodeRecord>(predicate: #Predicate { $0.showId == showId })
        let records = ((try? context.fetch(descriptor)) ?? []).filter { $0.status == .complete || $0.status == .downloading }
        for record in Self.recordsToEvict(current: records, limit: limit) {
            if record.status == .downloading {
                cancelDownload(episodeId: record.id)
            } else {
                DownloadCleanup.delete([record], from: context)
            }
        }
    }

    // Pulled out as a pure function for testability, mirroring DownloadCleanup.shouldAutoDelete.
    static func recordsToEvict(current: [DownloadedEpisodeRecord], limit: Int) -> [DownloadedEpisodeRecord] {
        guard limit > 0, current.count > limit else { return [] }
        return Array(current.sorted { $0.downloadedAt > $1.downloadedAt }.dropFirst(limit))
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
        let statusCode = (downloadTask.response as? HTTPURLResponse)?.statusCode
        let mimeType = downloadTask.response?.mimeType
        let headerBytes = Self.readHeaderBytes(of: location)
        let byteCount = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size] as? Int) ?? 0

        // A download task "succeeds" for any response the server finished sending, including a
        // 403/404/410 with a JSON or HTML body (expired signed link, geo-block, sign-in
        // interstitial). Saving that as <episodeId>.mp3 yields a download that completes and then
        // fails to play with no explanation — so refuse it here and let didCompleteWithError mark
        // the same tap-to-retry state a broken connection would.
        guard Self.isAcceptablePayload(statusCode: statusCode, mimeType: mimeType, headerBytes: headerBytes, byteCount: byteCount) else {
            reject(downloadTask)
            return
        }

        let fileExtension = Self.audioFileExtension(
            mimeType: mimeType, suggestedFilename: downloadTask.response?.suggestedFilename, headerBytes: headerBytes)
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
            reject(downloadTask)
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

    private func reject(_ task: URLSessionDownloadTask) {
        taskMapLock.withLock { _ = rejectedTaskIdentifiers.insert(task.taskIdentifier) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (episodeId, wasRejected) = taskMapLock.withLock {
            (episodeIdsByTaskIdentifier.removeValue(forKey: task.taskIdentifier),
             rejectedTaskIdentifiers.remove(task.taskIdentifier) != nil)
        }
        guard let episodeId else { return }
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
            // record — only mark .failed when the transfer itself broke, or when it completed but
            // didFinishDownloadingTo refused what arrived.
            if let error, (error as NSError).code == NSURLErrorCancelled { return }
            guard error != nil || wasRejected, let modelContainer = self.modelContainer else { return }
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

// MARK: - Downloaded file type detection

// AVFoundation identifies a *local* file's container by its path extension — it doesn't sniff a
// file:// URL the way it honors an HTTP response's Content-Type — so the extension a download is
// saved under decides whether it plays at all. The original rule copied URLResponse.suggestedFilename's
// extension verbatim (falling back to "mp3"), which broke two common enclosure shapes: an
// extension-less or script-style download endpoint ("/download/12345", "/play.php?id=1") serving
// AAC/M4A that got saved as ".mp3" or ".php", and a ".mp3" URL that is actually an MP4 container
// (hosts that transcode behind a stable URL). Trust order: the file's own unambiguous signature
// (the ground truth — the container is exactly what the leading bytes say), then the declared
// audio Content-Type, then a known audio extension from the URL/Content-Disposition, then the
// weak MPEG/ADTS frame-sync pattern, then "mp3" as the overwhelmingly most common podcast format.
extension DownloadManager {
    // Enough of the file to find a container signature (first 16 bytes) or the opening tag of a
    // web page after any BOM/whitespace/comment.
    static let headerSniffLength = 512
    // A finished transfer declared text/html that neither sniffs as audio nor opens with markup
    // is given the benefit of the doubt only if it's at least this large — a genuine episode
    // behind a misconfigured host is many megabytes, an error page never is.
    static let minimumPlausibleEpisodeBytes = 256 * 1024

    // Container extensions AVFoundation opens by name from a file:// URL. ogg/opus are included so
    // a feed serving them at least keeps an honest extension (AVPlayer can't decode Ogg Vorbis, and
    // only plays Opus in CAF/MP4 — a known gap, not something an extension can fix).
    private static let knownAudioExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "mp4", "aac", "wav", "aif", "aiff", "aifc", "caf", "flac", "ogg", "oga", "opus",
    ]

    private static let extensionsByMimeType: [String: String] = [
        "audio/mpeg": "mp3", "audio/mp3": "mp3", "audio/mpeg3": "mp3", "audio/x-mpeg-3": "mp3", "audio/x-mp3": "mp3",
        "audio/mp4": "m4a", "audio/x-m4a": "m4a", "audio/m4a": "m4a", "audio/mp4a-latm": "m4a", "audio/x-m4b": "m4b",
        "audio/aac": "aac", "audio/aacp": "aac", "audio/x-aac": "aac",
        "audio/wav": "wav", "audio/x-wav": "wav", "audio/wave": "wav", "audio/vnd.wave": "wav",
        "audio/aiff": "aiff", "audio/x-aiff": "aiff",
        "audio/flac": "flac", "audio/x-flac": "flac",
        "audio/ogg": "ogg", "audio/vorbis": "ogg", "audio/opus": "opus",
        "audio/x-caf": "caf",
    ]

    static func audioFileExtension(mimeType: String?, suggestedFilename: String?, headerBytes: Data) -> String {
        if let signature = containerFromSignature(headerBytes: headerBytes) {
            return signature
        }
        if let mimeType, let mapped = extensionsByMimeType[Self.normalizedMimeType(mimeType)] {
            return mapped
        }
        if let suggestedFilename {
            let urlExtension = (suggestedFilename as NSString).pathExtension.lowercased()
            if knownAudioExtensions.contains(urlExtension) {
                return urlExtension
            }
        }
        return containerFromFrameSync(headerBytes: headerBytes) ?? "mp3"
    }

    // The container implied by a file's leading bytes, or nil when they match no audio format
    // this recognizes.
    static func sniffedAudioExtension(headerBytes: Data) -> String? {
        containerFromSignature(headerBytes: headerBytes) ?? containerFromFrameSync(headerBytes: headerBytes)
    }

    // Tagged/boxed formats with a real multi-byte signature — unambiguous, so these outrank any
    // header or URL hint.
    private static func containerFromSignature(headerBytes: Data) -> String? {
        func matches(_ ascii: String, at offset: Int = 0) -> Bool {
            headerBytes.dropFirst(offset).starts(with: ascii.utf8)
        }
        if matches("ID3") { return "mp3" }
        if matches("ftyp", at: 4) { return "m4a" }
        if matches("RIFF") { return "wav" }
        if matches("FORM") { return "aiff" }
        if matches("fLaC") { return "flac" }
        if matches("OggS") { return "ogg" }
        if matches("caff") { return "caf" }
        return nil
    }

    // The bare MPEG frame-sync pattern — only 11-12 bits, so the weakest signal here and ranked
    // below the declared type and URL. 0xFFF sync with layer bits 00 is an ADTS AAC frame; any
    // other layer under an 0xFFE sync is an MPEG audio (MP3) frame.
    private static func containerFromFrameSync(headerBytes: Data) -> String? {
        guard headerBytes.count >= 2 else { return nil }
        let first = headerBytes[headerBytes.startIndex]
        let second = headerBytes[headerBytes.startIndex + 1]
        guard first == 0xFF else { return nil }
        if second & 0xF6 == 0xF0 { return "aac" }
        if second & 0xE0 == 0xE0 { return "mp3" }
        return nil
    }

    // Whether a finished transfer is worth keeping as an episode file at all.
    static func isAcceptablePayload(statusCode: Int?, mimeType: String?, headerBytes: Data, byteCount: Int) -> Bool {
        if let statusCode, !(200...299).contains(statusCode) { return false }
        return looksLikeAudioContent(mimeType: mimeType, headerBytes: headerBytes, byteCount: byteCount)
    }

    // False only when the payload is recognizably a web page rather than audio: markup in the
    // leading bytes, or a declared text/html type on something too small to be an episode.
    // Anything that sniffs as audio passes regardless of what the (often misconfigured)
    // Content-Type claims, and a large unrecognized octet stream — an MP3 with junk before its
    // first frame behind a host that labels everything text/html — is given the benefit of the
    // doubt rather than refused forever.
    static func looksLikeAudioContent(mimeType: String?, headerBytes: Data, byteCount: Int) -> Bool {
        if sniffedAudioExtension(headerBytes: headerBytes) != nil { return true }
        let leadingText = String(decoding: headerBytes.prefix(headerSniffLength), as: UTF8.self)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(["\u{FEFF}"]))
        if leadingText.hasPrefix("<!doctype") || leadingText.hasPrefix("<html") || leadingText.hasPrefix("<?xml") {
            return false
        }
        if let mimeType, Self.normalizedMimeType(mimeType) == "text/html", byteCount < minimumPlausibleEpisodeBytes {
            return false
        }
        return true
    }

    private static func normalizedMimeType(_ mimeType: String) -> String {
        // "audio/mpeg; charset=binary" → "audio/mpeg"
        mimeType.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
    }

    // The leading bytes of the finished download, read before didFinishDownloadingTo's temporary
    // file is moved (or, for a rejected payload, discarded by the system on return).
    private static func readHeaderBytes(of location: URL) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: location) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: headerSniffLength)) ?? Data()
    }
}
