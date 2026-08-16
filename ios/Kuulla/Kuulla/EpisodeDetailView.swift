import SwiftUI

struct EpisodeDetailView: View {
    let showId: String
    let episodeId: String

    @State private var episode: Episode?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var audioPlayer = AudioPlayer()

    private let catalogClient = PodcastCatalogClient()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let episode {
                    Text(episode.title)
                        .font(.title2)
                        .bold()

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
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                    if let audioURL = URL(string: episode.audioUrl) {
                        Button {
                            togglePlayback(url: audioURL)
                        } label: {
                            Label(audioPlayer.isPlaying ? "Pause" : "Play", systemImage: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    if let description = episode.description, !description.isEmpty {
                        Text("Show notes")
                            .font(.headline)
                            .padding(.top, 8)
                        Text(description)
                    } else {
                        Text("No show notes available for this episode.")
                            .foregroundStyle(.secondary)
                    }
                } else if let loadError {
                    Text(loadError)
                        .foregroundStyle(.red)
                } else if !isLoading {
                    Text("Episode not found.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .overlay {
            if isLoading {
                ProgressView()
            }
        }
        .navigationTitle(episode?.title ?? "Episode")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: episodeId) {
            await load()
        }
    }

    private func load() async {
        episode = nil
        loadError = nil
        isLoading = true
        do {
            episode = try await catalogClient.getEpisode(showId: showId, episodeId: episodeId)
        } catch {
            loadError = "Something went wrong while loading this episode. Please try again."
        }
        isLoading = false
    }

    private func togglePlayback(url: URL) {
        if audioPlayer.isPlaying {
            audioPlayer.pause()
        } else if audioPlayer.currentTime > 0 {
            audioPlayer.resume()
        } else {
            audioPlayer.play(url: url)
        }
    }
}

#Preview {
    NavigationStack {
        EpisodeDetailView(showId: "preview-show", episodeId: "preview-episode")
    }
}
