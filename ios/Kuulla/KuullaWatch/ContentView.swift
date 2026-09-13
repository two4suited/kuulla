import SwiftUI

/// Proves out the `WCSession` pairing — no feature UI yet (milestone #41, issue #581). Later
/// issues replace this with the synced now-playing / browse screens.
struct ContentView: View {
    @State private var isReachable = false

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: isReachable ? "iphone.gen3.radiowaves.left.and.right" : "iphone.slash")
                .font(.largeTitle)
                .foregroundStyle(isReachable ? .green : .secondary)
            Text(isReachable ? "iPhone connected" : "iPhone not reachable")
                .font(.footnote)
                .multilineTextAlignment(.center)
        }
        .padding()
        .task {
            await WatchConnectivitySession.shared.activate()
            for await reachable in await WatchConnectivitySession.shared.reachabilityUpdates {
                isReachable = reachable
            }
        }
    }
}

#Preview {
    ContentView()
}
