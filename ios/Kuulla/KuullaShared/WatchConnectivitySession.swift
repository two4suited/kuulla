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
    }

    fileprivate func handleReachabilityChange(_ reachable: Bool) {
        isReachable = reachable
        reachabilityContinuation?.yield(reachable)
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
