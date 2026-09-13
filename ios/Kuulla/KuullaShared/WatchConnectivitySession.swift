import Foundation
import WatchConnectivity

/// Thin wrapper around `WCSession`, mirroring `ApiClient`'s actor style. Compiled into both the
/// iOS and watchOS targets (shared file membership) so each side gets the same reachability
/// tracking without duplicating the delegate-bridging boilerplate.
actor WatchConnectivitySession {
    static let shared = WatchConnectivitySession()

    private(set) var isReachable = false
    private(set) var activationState: WCSessionActivationState = .notActivated

    private var delegate: SessionDelegate?
    private var reachabilityContinuation: AsyncStream<Bool>.Continuation?

    private init() {}

    // Safe to call more than once: WCSession.activate() is itself idempotent, and re-issuing it
    // is the only way to recover if the first attempt completed with an error (e.g. cold-launched
    // before the Watch finished pairing) — a guard on "have we tried before" would leave
    // isReachable stuck forever once that first attempt failed.
    func activate() {
        guard WCSession.isSupported() else { return }
        if delegate == nil {
            delegate = SessionDelegate(owner: self)
        }
        WCSession.default.delegate = delegate
        WCSession.default.activate()
    }

    /// Emits the current reachability immediately, then again on every change. Single-subscriber:
    /// a second concurrent subscriber would replace the first's continuation — fine today since
    /// only one view observes this.
    var reachabilityUpdates: AsyncStream<Bool> {
        AsyncStream { continuation in
            reachabilityContinuation = continuation
            continuation.yield(isReachable)
        }
    }

    fileprivate func handleActivation(state: WCSessionActivationState, error: Error?) {
        activationState = state
        if let error {
            // No retry loop here — activate() itself is idempotent, so the next foreground or
            // scene-reconnect calling activate() again is what actually recovers.
            print("WatchConnectivitySession: activation completed with error: \(error)")
        }
        if state == .activated {
            // Closes a cold-launch race (#582): a publish attempted before activation finished
            // (or a subscriber that checked reachability in that same window) got no signal to
            // try again. Re-yielding whatever reachability already settled on gives any
            // reachable-only watcher (e.g. KuullaApp's now-playing republish) one more chance to
            // fire now that publish() can actually go through.
            reachabilityContinuation?.yield(isReachable)
        }
    }

    fileprivate func handleReachabilityChange(_ reachable: Bool) {
        isReachable = reachable
        reachabilityContinuation?.yield(reachable)
    }

    private static let nowPlayingContextKey = "nowPlaying"
    private var lastAppliedNowPlayingSequence = 0

    // Application context (not a message) is the right channel here: it's WCSession's
    // "replace whatever the counterpart last received with this" slot, which is exactly what a
    // now-playing snapshot is — only the latest state ever matters, unlike a queued message.
    // Silently drops the update if the session isn't activated yet; the next real state change
    // (or the activation/reachability-triggered republish above) supersedes it once activation
    // completes.
    //
    // `sequence` must be assigned by the caller synchronously, before spawning whatever Task
    // calls this — AudioPlayer's publishToWatch() does this precisely so that two rapid state
    // changes (e.g. pause then seek) can't have their unstructured Tasks reach this actor out of
    // creation order and leave the watch displaying the older, stale one.
    func publish(nowPlaying state: WatchNowPlayingState?, sequence: Int) {
        guard activationState == .activated else { return }
        guard sequence >= lastAppliedNowPlayingSequence else { return }
        lastAppliedNowPlayingSequence = sequence
        do {
            var context: [String: Any] = [:]
            if let state {
                context[Self.nowPlayingContextKey] = try JSONEncoder().encode(state)
            }
            try WCSession.default.updateApplicationContext(context)
        } catch {
            print("WatchConnectivitySession: failed to update application context: \(error)")
        }
    }
}

// WCSessionDelegate is an Objective-C protocol with no Sendable annotations, so the delegate
// itself must be a plain NSObject subclass — actors can't inherit from NSObject. It forwards
// every callback to the owning actor rather than touching any shared state itself.
@preconcurrency
private final class SessionDelegate: NSObject, WCSessionDelegate {
    private weak var owner: WatchConnectivitySession?

    init(owner: WatchConnectivitySession) {
        self.owner = owner
    }

    func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { await owner?.handleActivation(state: activationState, error: error) }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        Task { await owner?.handleReachabilityChange(session.isReachable) }
    }

    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    #endif
}
