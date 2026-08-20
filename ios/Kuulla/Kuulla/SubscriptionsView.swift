import SwiftUI

struct SubscriptionsView: View {
    @State private var subscriptions: [Subscription] = []
    @State private var unplayedCounts: [String: UnplayedCounts.Count] = [:]
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var confirmingShowId: String?
    @State private var isUnsubscribeBusy = false
    @State private var unsubscribeError: String?

    private let subscriptionClient = SubscriptionClient()

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 16)]

    var body: some View {
        ScrollView {
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .padding()
            } else if isLoading {
                ProgressView()
                    .padding()
            } else if subscriptions.isEmpty {
                Text("You haven't subscribed to any shows yet.")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(subscriptions) { subscription in
                        SubscriptionTile(
                            subscription: subscription,
                            unplayedCount: unplayedCounts[subscription.showId],
                            isConfirming: confirmingShowId == subscription.showId,
                            isBusy: isUnsubscribeBusy,
                            onUnsubscribeTapped: { confirmingShowId = subscription.showId },
                            onConfirm: { Task { await unsubscribe(showId: subscription.showId) } },
                            onCancel: { confirmingShowId = nil })
                    }
                }
                .padding()

                if let unsubscribeError {
                    Text(unsubscribeError)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }
            }
        }
        .navigationTitle("Subscriptions")
        .task {
            await loadSubscriptions()
        }
        .refreshable {
            await loadSubscriptions()
        }
    }

    private func loadSubscriptions() async {
        guard !isLoading else { return }

        isLoading = true
        errorMessage = nil
        // Clears any leftover unsubscribe state from a prior failed attempt so a stale error
        // or confirm prompt doesn't linger across a reload.
        unsubscribeError = nil
        confirmingShowId = nil

        do {
            let results = try await subscriptionClient.getSubscriptions()
                .sorted { $0.showTitle.localizedCaseInsensitiveCompare($1.showTitle) == .orderedAscending }
            if !Task.isCancelled {
                subscriptions = results
            }
        } catch {
            if !Task.isCancelled {
                errorMessage = "Something went wrong while loading your subscriptions. Please try again."
            }
        }

        // Always clears the flag, even if cancelled — mirrors LibraryView.loadShows(): the
        // best-effort badge fetch below must run after loading state clears, not only at the end.
        isLoading = false
        guard !Task.isCancelled, errorMessage == nil else { return }

        // Best-effort, run after the grid has already rendered: unplayed badges are supplementary,
        // so a failure here shouldn't hide the already-loaded subscriptions grid behind an error.
        if let newEpisodes = try? await subscriptionClient.getNewEpisodes(), !Task.isCancelled {
            unplayedCounts = UnplayedCounts.compute(from: newEpisodes)
        }
    }

    private func unsubscribe(showId: String) async {
        guard !isUnsubscribeBusy else { return }

        isUnsubscribeBusy = true
        unsubscribeError = nil
        let removed = subscriptions.first { $0.showId == showId }
        subscriptions.removeAll { $0.showId == showId }
        confirmingShowId = nil

        do {
            try await subscriptionClient.unsubscribe(showId: showId)
        } catch {
            // Re-add only if a concurrent reload (pull-to-refresh) hasn't already settled the
            // list one way or the other — otherwise this stale snapshot could reintroduce a show
            // the refresh legitimately dropped, or duplicate one it already restored.
            if let removed, !subscriptions.contains(where: { $0.showId == removed.showId }) {
                subscriptions.append(removed)
                subscriptions.sort { $0.showTitle.localizedCaseInsensitiveCompare($1.showTitle) == .orderedAscending }
            }
            unsubscribeError = "Something went wrong while unsubscribing. Please try again."
        }

        isUnsubscribeBusy = false
    }
}

private struct SubscriptionTile: View {
    let subscription: Subscription
    let unplayedCount: UnplayedCounts.Count?
    let isConfirming: Bool
    let isBusy: Bool
    let onUnsubscribeTapped: () -> Void
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            NavigationLink(value: CatalogRoute.show(id: subscription.showId)) {
                VStack(alignment: .leading, spacing: 6) {
                    ZStack(alignment: .topTrailing) {
                        AsyncImage(url: subscription.showArtworkUrl.flatMap(URL.init)) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Color.secondary.opacity(0.2)
                        }
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                        if let unplayedCount, unplayedCount.unplayed > 0 {
                            let capped = UnplayedCounts.newEpisodesPerShowCap
                            Text(unplayedCount.hitCap ? "\(capped)+" : "\(unplayedCount.unplayed)")
                                .font(.caption2)
                                .fontWeight(.bold)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.accentColor, in: Capsule())
                                .padding(4)
                        }
                    }

                    Text(subscription.showTitle)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }
            }
            .buttonStyle(.plain)

            if isConfirming {
                Text("Unsubscribe from \(subscription.showTitle)?")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button("Confirm", role: .destructive, action: onConfirm)
                    Button("Cancel", action: onCancel)
                }
                .font(.caption2)
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(isBusy)
            } else {
                Button("Unsubscribe", action: onUnsubscribeTapped)
                    .font(.caption2)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(.red)
            }
        }
    }
}

#Preview {
    NavigationStack {
        SubscriptionsView()
    }
}
