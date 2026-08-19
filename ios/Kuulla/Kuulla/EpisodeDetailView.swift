import SwiftData
import SwiftUI

struct EpisodeDetailView: View {
    let showId: String
    let episodeId: String

    @Environment(\.episodeSyncEngine) private var syncEngine
    @Environment(\.modelContext) private var modelContext

    @State private var episode: Episode?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var audioPlayer = AudioPlayer.shared

    @State private var stateRecord: EpisodeStateRecord?
    @State private var progressTrackingTask: Task<Void, Never>?

    private let catalogClient = PodcastCatalogClient()

    private var status: EpisodeStatus { EpisodeStatus(record: stateRecord) }

    // AudioPlayer is a single shared instance, so isPlaying/currentURL are global, not scoped to
    // this screen's episode — a plain `audioPlayer.isPlaying` check would show "Pause" (and treat
    // a tap as pause-this-episode) while a *different* episode is actually playing.
    private func isPlaying(_ url: URL) -> Bool {
        audioPlayer.isPlaying && audioPlayer.currentURL == url
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let episode {
                    HStack(alignment: .firstTextBaseline) {
                        Text(episode.title)
                            .font(.title2)
                            .bold()
                        Spacer()
                        StatusBadge(status: status)
                    }

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
                            Label(isPlaying(audioURL) ? "Pause" : "Play", systemImage: isPlaying(audioURL) ? "pause.fill" : "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Button(status == .played ? "Mark as Unplayed" : "Mark as Played") {
                        Task { await toggleCompleted() }
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)

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
        .onDisappear {
            progressTrackingTask?.cancel()
            progressTrackingTask = nil
        }
    }

    private func load() async {
        episode = nil
        loadError = nil
        isLoading = true
        do {
            episode = try await catalogClient.getEpisode(showId: showId, episodeId: episodeId)
        } catch {
            if !Task.isCancelled {
                loadError = "Something went wrong while loading this episode. Please try again."
            }
        }
        isLoading = false

        loadLocalState()
    }

    private func loadLocalState() {
        stateRecord = (try? modelContext.fetch(Self.stateDescriptor(for: episodeId)))?.first
    }

    private static func stateDescriptor(for episodeId: String) -> FetchDescriptor<EpisodeStateRecord> {
        FetchDescriptor<EpisodeStateRecord>(predicate: #Predicate { $0.id == episodeId })
    }

    private func togglePlayback(url: URL) {
        if isPlaying(url) {
            audioPlayer.pause()
            stopProgressTracking()
            Task { await persistProgress(completed: false) }
        } else if audioPlayer.currentURL == url {
            audioPlayer.resume()
            startProgressTracking()
        } else {
            let startPosition = TimeInterval(stateRecord?.positionSeconds ?? 0)
            // Assigned only when actually starting playback for this URL (not merely on screen
            // appearance) — AudioPlayer has one completion-callback slot shared across the app, and
            // starting playback here always fully replaces whatever was playing before, so tying
            // the callback to this exact moment keeps it pointed at whichever episode is actually
            // playing rather than being silently stolen by a screen that never pressed play.
            audioPlayer.onDidFinishPlaying = { finishedURL in
                guard finishedURL == url else { return }
                self.stopProgressTracking()
                Task { await self.persistProgress(completed: true) }
            }
            audioPlayer.play(url: url, startPosition: startPosition)
            startProgressTracking()
        }
    }

    private func startProgressTracking() {
        stopProgressTracking()
        progressTrackingTask = Task {
            while !Task.isCancelled {
                // Deliberately longer than SyncEngine's own debounce window (5s, SyncEngine.swift):
                // recordChanged() restarts that debounce on every write, so ticking at exactly the
                // debounce interval would perpetually re-arm it and could starve the actual push for
                // as long as playback continues. A longer interval here lets each debounce fire
                // before the next local write arrives.
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                await persistProgress(completed: false)
            }
        }
    }

    private func stopProgressTracking() {
        progressTrackingTask?.cancel()
        progressTrackingTask = nil
    }

    private func toggleCompleted() async {
        let newCompleted = status != .played
        if newCompleted {
            stopProgressTracking()
        }
        let position = newCompleted ? Int(episode?.duration ?? 0) : (stateRecord?.positionSeconds ?? 0)
        await persist(positionSeconds: position, completed: newCompleted)
    }

    private func persistProgress(completed: Bool) async {
        // A periodic tick always reports completed: false — it must never downgrade a record that
        // was just marked completed (via natural finish or the manual toggle), since a tick can
        // still be in flight right after either of those events.
        if !completed && stateRecord?.completed == true {
            return
        }

        let position = Int(audioPlayer.currentTime)
        guard position > 0 || completed else { return }
        await persist(positionSeconds: position, completed: completed)
    }

    private func persist(positionSeconds: Int, completed: Bool) async {
        guard let syncEngine else { return }
        let updatedAt = Date()
        try? await syncEngine.write { context in
            let descriptor = Self.stateDescriptor(for: episodeId)
            if let existing = try context.fetch(descriptor).first {
                existing.showId = showId
                existing.positionSeconds = positionSeconds
                existing.completed = completed
                existing.updatedAt = updatedAt
                existing.isDirty = true
            } else {
                context.insert(EpisodeStateRecord(
                    id: episodeId, showId: showId, positionSeconds: positionSeconds,
                    completed: completed, updatedAt: updatedAt, isDirty: true))
            }
        }
        // Set directly from the values just written rather than re-reading through modelContext:
        // that's a different ModelContext instance than the one syncEngine.write just saved
        // through, and isn't guaranteed to observe the write synchronously.
        stateRecord = EpisodeStateRecord(
            id: episodeId, showId: showId, positionSeconds: positionSeconds, completed: completed, updatedAt: updatedAt)
    }
}

#Preview {
    NavigationStack {
        EpisodeDetailView(showId: "preview-show", episodeId: "preview-episode")
    }
}
