import SwiftUI

// Presented from EpisodeDetailView's sleep timer button (#208). Talks directly to
// AudioPlayer.shared rather than being scoped to a specific episode — a sleep timer stops
// whatever's currently playing, mirroring how AudioPlayer's own play/pause commands work — and
// to SettingsClient to remember the user's last-picked duration as the new global default.
struct SleepTimerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var audioPlayer = AudioPlayer.shared
    @State private var defaultDurationMinutes: Int?
    @State private var isLoadingDefault = false
    @State private var saveDefaultError: String?

    private let settingsClient = SettingsClient()

    var body: some View {
        NavigationStack {
            Form {
                if audioPlayer.sleepTimerEndOfEpisodeEnabled {
                    activeEndOfEpisodeSection
                } else if let remainingLabel = Self.formatRemaining(audioPlayer.sleepTimerRemainingSeconds) {
                    activeCountdownSection(remainingLabel: remainingLabel)
                } else {
                    inactiveSection
                }
            }
            .navigationTitle("Sleep Timer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay {
                if isLoadingDefault {
                    ProgressView()
                }
            }
            .task {
                await loadDefaultDuration()
            }
        }
    }

    private var activeEndOfEpisodeSection: some View {
        Section {
            Text("Playback will stop at the end of this episode.")
            Button("Cancel Sleep Timer", role: .destructive) {
                audioPlayer.cancelSleepTimer()
            }
        }
    }

    private func activeCountdownSection(remainingLabel: String) -> some View {
        Section {
            Text("Stopping in \(remainingLabel)")
                .font(.title2)
                .monospacedDigit()
            HStack {
                Button("-5 min") { audioPlayer.adjustSleepTimer(byMinutes: -5) }
                    .buttonStyle(.bordered)
                Spacer()
                Button("+5 min") { audioPlayer.adjustSleepTimer(byMinutes: 5) }
                    .buttonStyle(.bordered)
            }
            Button("Cancel Sleep Timer", role: .destructive) {
                audioPlayer.cancelSleepTimer()
            }
        }
    }

    private var inactiveSection: some View {
        Section {
            ForEach(SleepTimerDuration.allCases) { option in
                Button {
                    start(minutes: option.rawValue)
                } label: {
                    HStack {
                        Text(option.label)
                        if defaultDurationMinutes == option.rawValue {
                            Spacer()
                            Image(systemName: "checkmark")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Button("End of Episode") {
                audioPlayer.startSleepTimerForEndOfEpisode()
            }
        } footer: {
            if let saveDefaultError {
                Text(saveDefaultError)
                    .foregroundStyle(.red)
            }
        }
    }

    // Pulled out as a pure function for testability, mirroring AudioPlayer's own
    // shouldTriggerOutroSkip/EpisodeDetailView's resolvedPlaybackURL test seams.
    static func formatRemaining(_ seconds: TimeInterval?) -> String? {
        guard let seconds else { return nil }
        let totalSeconds = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private func loadDefaultDuration() async {
        isLoadingDefault = true
        defaultDurationMinutes = try? await settingsClient.getSettings().sleepTimerDefaultDurationMinutes
        isLoadingDefault = false
    }

    // Starting a duration also remembers it as the new default (#208) — best-effort: a failed
    // save shouldn't undo the timer that's already running, it just means the next time this
    // sheet opens it won't be pre-checked with this pick.
    private func start(minutes: Int) {
        audioPlayer.startSleepTimer(minutes: minutes)
        defaultDurationMinutes = minutes
        saveDefaultError = nil
        Task {
            do {
                _ = try await settingsClient.updateSleepTimerDefaultDuration(minutes)
            } catch {
                saveDefaultError = "Something went wrong while saving your default duration."
            }
        }
    }
}

#Preview {
    SleepTimerSheet()
}
