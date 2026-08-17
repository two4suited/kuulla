import SwiftUI

struct ShowDetailView: View {
    let showId: String

    @State private var show: Show?
    @State private var isLoadingShow = false
    @State private var showError: String?
    @State private var episodes: [Episode] = []
    @State private var continuationToken: String?
    @State private var isLoadingEpisodes = false
    @State private var episodeError: String?
    @State private var isSubscribed = false
    @State private var isSubscriptionBusy = false
    @State private var subscriptionError: String?
    // Set once the user has manually subscribed/unsubscribed, so the initial (slower)
    // subscription-status fetch doesn't clobber a faster, more current toggle result.
    @State private var hasToggledSubscription = false

    private let catalogClient = PodcastCatalogClient()
    private let subscriptionClient = SubscriptionClient()

    var body: some View {
        List {
            if let show {
                Section {
                    ShowHeader(
                        show: show,
                        isSubscribed: isSubscribed,
                        isSubscriptionBusy: isSubscriptionBusy,
                        subscriptionError: subscriptionError,
                        onSubscribeTapped: { Task { await toggleSubscription() } }
                    )
                }
                .listRowSeparator(.hidden)
            } else if let showError {
                Text(showError)
                    .foregroundStyle(.red)
            } else if !isLoadingShow {
                Text("Show not found.")
                    .foregroundStyle(.secondary)
            }

            if show != nil || isLoadingEpisodes || episodeError != nil {
                Section("Episodes") {
                    if let episodeError {
                        Text(episodeError)
                            .foregroundStyle(.red)
                    } else if episodes.isEmpty && !isLoadingEpisodes {
                        Text("No episodes found for this show.")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(episodes) { episode in
                        NavigationLink(value: CatalogRoute.episode(showId: showId, episodeId: episode.id)) {
                            EpisodeRow(episode: episode)
                        }
                    }

                    if isLoadingEpisodes {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    } else if continuationToken != nil {
                        Button("Load more") {
                            Task { await loadMoreEpisodes() }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(show?.title ?? "Show")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isLoadingShow {
                ProgressView()
            }
        }
        .task(id: showId) {
            await loadShow()
        }
    }

    private func loadShow() async {
        show = nil
        showError = nil
        episodes = []
        continuationToken = nil
        episodeError = nil
        isLoadingEpisodes = false
        isSubscribed = false
        isSubscriptionBusy = false
        subscriptionError = nil
        hasToggledSubscription = false

        isLoadingShow = true
        do {
            show = try await catalogClient.getShow(id: showId)
        } catch {
            if !Task.isCancelled {
                showError = "Something went wrong while loading this show. Please try again."
            }
        }
        isLoadingShow = false

        if show != nil {
            await loadMoreEpisodes()
            await loadSubscriptionStatus()
        }
    }

    private func loadSubscriptionStatus() async {
        do {
            let subscriptions = try await subscriptionClient.getSubscriptions()
            guard !Task.isCancelled, !hasToggledSubscription else { return }
            isSubscribed = subscriptions.contains { $0.showId == showId }
        } catch {
            // Not authenticated or the call failed; leave the subscribe button in its default state.
        }
    }

    private func toggleSubscription() async {
        guard !isSubscriptionBusy else { return }

        isSubscriptionBusy = true
        subscriptionError = nil
        hasToggledSubscription = true
        let previouslySubscribed = isSubscribed
        isSubscribed.toggle()

        do {
            if previouslySubscribed {
                try await subscriptionClient.unsubscribe(showId: showId)
            } else {
                _ = try await subscriptionClient.subscribe(showId: showId)
            }
        } catch {
            if !Task.isCancelled {
                isSubscribed = previouslySubscribed
                subscriptionError = previouslySubscribed
                    ? "Something went wrong while unsubscribing. Please try again."
                    : "Something went wrong while subscribing. Please try again."
            }
        }

        isSubscriptionBusy = false
    }

    private func loadMoreEpisodes() async {
        guard !isLoadingEpisodes else { return }

        isLoadingEpisodes = true
        episodeError = nil

        do {
            let page = try await catalogClient.getEpisodes(showId: showId, continuationToken: continuationToken)
            episodes.append(contentsOf: page.items)
            continuationToken = page.continuationToken
        } catch {
            if !Task.isCancelled {
                episodeError = "Something went wrong while loading episodes. Please try again."
            }
        }

        isLoadingEpisodes = false
    }
}

private struct ShowHeader: View {
    let show: Show
    let isSubscribed: Bool
    let isSubscriptionBusy: Bool
    let subscriptionError: String?
    let onSubscribeTapped: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 16) {
                AsyncImage(url: show.artworkUrl.flatMap(URL.init)) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.secondary.opacity(0.2)
                }
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 4) {
                    Text(show.title)
                        .font(.title3)
                        .bold()
                    Text(show.author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if !show.categories.isEmpty {
                        Text(show.categories.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let description = show.description, !description.isEmpty {
                        Text(description)
                            .font(.footnote)
                            .padding(.top, 4)
                    }
                }
            }

            Button(action: onSubscribeTapped) {
                if isSubscriptionBusy {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text(isSubscribed ? "Unsubscribe" : "Subscribe")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .tint(isSubscribed ? .red : .accentColor)
            .disabled(isSubscriptionBusy)

            if let subscriptionError {
                Text(subscriptionError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct EpisodeRow: View {
    let episode: Episode

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(episode.title)
                .font(.body)
                .lineLimit(2)

            HStack(spacing: 4) {
                if let publishedAt = episode.publishedAt {
                    Text(publishedAt.formatted(date: .abbreviated, time: .omitted))
                }
                if episode.publishedAt != nil && episode.duration != nil {
                    Text("·")
                }
                if let duration = episode.duration {
                    Text(EpisodeFormatting.formatDuration(duration))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    NavigationStack {
        ShowDetailView(showId: "preview-show")
    }
}
