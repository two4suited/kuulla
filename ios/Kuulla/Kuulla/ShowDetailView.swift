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

    private let catalogClient = PodcastCatalogClient()

    var body: some View {
        List {
            if let show {
                Section {
                    ShowHeader(show: show)
                }
                .listRowSeparator(.hidden)
            } else if let showError {
                Text(showError)
                    .foregroundStyle(.red)
            }

            if !episodes.isEmpty || isLoadingEpisodes || episodeError != nil {
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

        isLoadingShow = true
        do {
            show = try await catalogClient.getShow(id: showId)
        } catch {
            showError = "Something went wrong while loading this show. Please try again."
        }
        isLoadingShow = false

        if show != nil {
            await loadMoreEpisodes()
        }
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
            episodeError = "Something went wrong while loading episodes. Please try again."
        }

        isLoadingEpisodes = false
    }
}

private struct ShowHeader: View {
    let show: Show

    var body: some View {
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
