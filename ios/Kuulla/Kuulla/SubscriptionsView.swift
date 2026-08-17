import SwiftUI

struct SubscriptionsView: View {
    @State private var subscriptions: [Subscription] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

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
                        NavigationLink(value: CatalogRoute.show(id: subscription.showId)) {
                            SubscriptionTile(subscription: subscription)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
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
        defer { isLoading = false }

        do {
            let results = try await subscriptionClient.getSubscriptions()
                .sorted { $0.showTitle.localizedCaseInsensitiveCompare($1.showTitle) == .orderedAscending }
            guard !Task.isCancelled else { return }
            subscriptions = results
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = "Something went wrong while loading your subscriptions. Please try again."
        }
    }
}

private struct SubscriptionTile: View {
    let subscription: Subscription

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: subscription.showArtworkUrl.flatMap(URL.init)) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.secondary.opacity(0.2)
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(subscription.showTitle)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
    }
}

#Preview {
    NavigationStack {
        SubscriptionsView()
    }
}
