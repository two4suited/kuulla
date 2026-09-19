import BackgroundTasks
import Foundation
import SwiftData

// The result of one POST /api/sync/{domain} round trip (docs/sync-conventions.md), translated
// from the domain's wire DTOs back into local `Syncable` records.
struct SyncPushResult<Record> {
    let serverChanges: [Record]
    let syncedAt: Date
    let hash: String
}

// The domain-specific half of a sync: encoding local records for the wire, calling that domain's
// batch endpoint, and decoding the response back into `Record` instances. SyncEngine owns
// everything that's the same for every domain (cursor bookkeeping, dirty-record collection,
// debounce, trigger wiring); an adapter owns the parts that necessarily differ per domain until
// #84 generalizes the server side too.
protocol SyncAdapter: Sendable {
    associatedtype Record: Syncable

    // Matches the server's {domain} segment and this engine's SyncCursor row.
    var domain: String { get }

    func push(
        deviceId: String,
        lastSyncedAt: Date,
        localHash: String,
        dirtyRecords: [Record]
    ) async throws -> SyncPushResult<Record>

    // Upsert one server-returned record into `context`, matching on `id`. Always called from
    // inside the engine's own ModelContext.
    func apply(_ record: Record, in context: ModelContext) throws

    // Runs after a successful server round trip, including a hash-matched no-op response.
    func didCompleteSync(in context: ModelContext) throws
}

extension SyncAdapter {
    func didCompleteSync(in context: ModelContext) throws {}
}

// Generic local-store reconciliation for one Syncable domain: collects dirty records, debounces
// pushes after a local write, calls the domain's batch endpoint via `adapter`, applies the
// server's delta back into SwiftData, and maintains the domain's SyncCursor. One instance per
// domain (e.g. episodes, and eventually settings) sharing the same ModelContainer.
actor SyncEngine<Adapter: SyncAdapter> {
    // Immutable and Sendable, so readable from the nonisolated BGTaskScheduler wiring below
    // without hopping onto the actor.
    nonisolated let domain: String

    private let container: ModelContainer
    private let adapter: Adapter
    private let deviceId: String
    private let debounceInterval: Duration

    // A ModelContext isn't Sendable and must be used from a single, consistent isolation domain.
    // An actor's own `init` runs on whatever thread constructs it (often the main thread, e.g.
    // from KuullaApp's init), so building the context eagerly there — then touching it later from
    // this actor's executor — trips SwiftData's "unbinding from the main queue" diagnostic.
    // Deferring construction to first access inside an isolated method binds it correctly instead.
    private lazy var context = ModelContext(container)

    private var debounceTask: Task<Void, Never>?
    private var isSyncing = false
    // Callers that reached syncNow() while a sync was already in flight, parked here until that
    // run (and any follow-up round it does for their newly-dirty state) completes — so `await
    // syncNow()` always returns after a real pull, not just after scheduling one. EpisodeDetailView's
    // foreground resume re-check (#241) relies on this to evaluate against freshly pulled state.
    private var syncWaiters: [CheckedContinuation<Void, Never>] = []
    // Set when a sync is requested while one is already running, so the newly-dirty state isn't
    // lost — the in-flight sync's snapshot of dirty records may already be stale by then.
    private var syncPending = false
    // Set by `write` when it runs while a sync is in flight. Actors are reentrant across `await`,
    // so a local write can land in the gap between performSync snapshotting its dirty records and
    // the push for that snapshot actually completing. When that happens we skip clearing isDirty
    // for this round entirely, rather than risk clobbering the new write — resending an
    // already-accepted record next round is harmless under last-write-wins, but losing an edit
    // permanently isn't.
    private var writeOccurredDuringSync = false

    init(
        modelContainer: ModelContainer,
        adapter: Adapter,
        deviceId: String = DeviceIdentity.current,
        debounceInterval: Duration = .seconds(5)
    ) {
        self.container = modelContainer
        self.domain = adapter.domain
        self.adapter = adapter
        self.deviceId = deviceId
        self.debounceInterval = debounceInterval
    }

    // Call after writing a local change and marking it `isDirty = true`. Schedules a push in
    // `debounceInterval`, restarting the timer if one is already pending, so a burst of local
    // writes (e.g. dragging a scrubber) produces one network call instead of many.
    func recordChanged() {
        debounceTask?.cancel()
        debounceTask = Task { [debounceInterval] in
            try? await Task.sleep(for: debounceInterval)
            guard !Task.isCancelled else { return }
            // Clear the reference to this very task before calling syncNow() — syncNow()
            // cancels `debounceTask` to drop any *pending* debounce, and since Task cancellation
            // is cooperative and propagates to in-flight `await`s (including the network call
            // inside performSync), leaving the reference in place would have syncNow() cancel
            // the task it's currently running in, aborting its own push mid-flight.
            debounceTask = nil
            await syncNow()
        }
    }

    // Runs sync immediately, bypassing the debounce. Use for launch, foreground resume, and
    // BGAppRefreshTask triggers. Awaiting this always returns after a sync has actually
    // completed — if one was already in flight, this awaits that run rather than returning early.
    //
    // `requestFollowUpIfSyncing` (default true): when a run is already in flight, also queue a
    // follow-up round so a caller that has just written dirty state still gets it pushed. Pass
    // false when the caller only needs local state to be *fresh* (e.g. a foreground read-back)
    // and shouldn't force a second POST just to wait.
    func syncNow(requestFollowUpIfSyncing: Bool = true) async {
        debounceTask?.cancel()
        debounceTask = nil

        guard !isSyncing else {
            // A run is already going. Optionally ask it to do a follow-up round for anything
            // dirty since it snapshotted, then park until it finishes so this await reflects a
            // completed pull. The first caller still runs the loop inline, so its cancellation
            // (e.g. a BGAppRefreshTask expiring) still propagates into performSync.
            if requestFollowUpIfSyncing {
                syncPending = true
            }
            await withCheckedContinuation { syncWaiters.append($0) }
            return
        }
        isSyncing = true
        // Runs on the actor with no await between clearing isSyncing and draining — so any caller
        // that saw isSyncing == true is guaranteed to be parked in syncWaiters, not racing a
        // fresh run — and in a defer so a stray throw can't strand parked callers forever.
        defer {
            isSyncing = false
            let waiters = syncWaiters
            syncWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }

        repeat {
            syncPending = false
            writeOccurredDuringSync = false
            await performSync()
        } while syncPending
    }

    private func performSync() async {
        do {
            let (cursor, cursorIsNew) = try cursor()
            let dirty = try context.fetch(
                FetchDescriptor<Adapter.Record>(predicate: #Predicate { $0.isDirty == true })
            )

            let result = try await adapter.push(
                deviceId: deviceId,
                lastSyncedAt: cursor.lastSyncedAt,
                localHash: cursor.localHash,
                dirtyRecords: dirty
            )

            // Nothing local to push and the server's hash matches what we already have: the
            // collections agree, so skip touching the store. Still save if this sync created a
            // fresh cursor, or that insert is lost the moment the process exits before any other
            // sync writes something.
            if dirty.isEmpty, result.serverChanges.isEmpty, result.hash == cursor.localHash {
                try adapter.didCompleteSync(in: context)
                if cursorIsNew || context.hasChanges {
                    try context.save()
                }
                return
            }

            if !writeOccurredDuringSync {
                for record in dirty {
                    record.isDirty = false
                }
            }
            for record in result.serverChanges {
                try adapter.apply(record, in: context)
            }
            try adapter.didCompleteSync(in: context)

            cursor.lastSyncedAt = result.syncedAt
            cursor.localHash = result.hash

            try context.save()
        } catch {
            // Leave dirty records and the cursor untouched so the next trigger retries.
        }
    }

    private func cursor() throws -> (SyncCursor, isNew: Bool) {
        let domain = adapter.domain
        let descriptor = FetchDescriptor<SyncCursor>(predicate: #Predicate { $0.domain == domain })
        if let existing = try context.fetch(descriptor).first {
            return (existing, false)
        }
        let cursor = SyncCursor(domain: domain, deviceId: deviceId)
        context.insert(cursor)
        return (cursor, true)
    }
}

extension SyncEngine {
    // The entry point for local writes: callers (e.g. a playback view recording a scrub) run
    // `mutate` against the engine's own ModelContext — the only one that's ever fed to `adapter`
    // — rather than the app's environment-provided context, so a write here is guaranteed to be
    // visible to the next sync. Marks the touched record dirty implicitly by whatever `mutate`
    // does, saves, and schedules the debounced push.
    func write(_ mutate: (ModelContext) throws -> Void) async rethrows {
        try mutate(context)
        do {
            try context.save()
        } catch {
            // A failed save here means the caller's local write never reached disk — surface it
            // loudly in debug builds rather than silently scheduling a sync of state that isn't
            // actually persisted.
            assertionFailure("SyncEngine.write failed to save: \(error)")
        }
        if isSyncing {
            writeOccurredDuringSync = true
        }
        recordChanged()
    }

    // Reads via this engine's own ModelContext — the only one `write`/`syncNow` ever save
    // through. A caller that just called `write` or `syncNow` and immediately reads back through
    // its own `@Environment(\.modelContext)` instance instead risks observing stale state (two
    // ModelContext instances over the same store aren't guaranteed to see each other's saves
    // immediately) — the exact hazard EpisodeDetailView.restoreAutoPlayed's doc comment works
    // around ad hoc. This is the general form: any single-context read after an engine write.
    func read<T>(_ fetch: (ModelContext) throws -> T) async rethrows -> T {
        try fetch(context)
    }
}

// Background-refresh trigger wiring, so a position update made on Web shows up here without the
// user having to background/foreground the app. Each domain gets its own BGAppRefreshTask
// identifier — add it to Info.plist's BGTaskSchedulerPermittedIdentifiers when adding a domain.
extension SyncEngine {
    nonisolated var backgroundTaskIdentifier: String { "com.kuulla.app.sync.\(domain)" }

    // Must be called once, before the app finishes launching — typically from the App struct's
    // `init()`, which SwiftUI runs before the first scene appears. BGTaskScheduler requires every
    // identifier to be registered before launch completes, regardless of whether a refresh is
    // ever scheduled.
    nonisolated func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundTaskIdentifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { await self.handleBackgroundRefresh(refreshTask) }
        }
    }

    // Queues the next periodic refresh; call when the app enters the background. iOS decides the
    // actual run time within its own budget, so `earliestBeginDelay` is a lower bound, not a promise.
    nonisolated func scheduleBackgroundRefresh(earliestBeginDelay: TimeInterval = 15 * 60) {
        let request = BGAppRefreshTaskRequest(identifier: backgroundTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: earliestBeginDelay)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func handleBackgroundRefresh(_ task: BGAppRefreshTask) async {
        // Reschedule up front — iOS only grants one run per submission, so if we don't queue the
        // next one now, refreshes stop after the first.
        scheduleBackgroundRefresh()

        let syncTask = Task { await syncNow() }
        task.expirationHandler = { syncTask.cancel() }
        await syncTask.value
        task.setTaskCompleted(success: !syncTask.isCancelled)
    }
}

// A stable per-install identifier sent with every sync request (docs/sync-conventions.md:
// used for conflict-resolution debugging/telemetry, never for LWW arbitration itself).
enum DeviceIdentity {
    private static let userDefaultsKey = "com.kuulla.app.deviceId"

    static var current: String {
        if let existing = UserDefaults.standard.string(forKey: userDefaultsKey) {
            return existing
        }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: userDefaultsKey)
        return generated
    }
}
