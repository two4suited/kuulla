import SwiftUI

// Presented from EpisodeDetailView's sleep timer button (#208). Talks directly to
// AudioPlayer.shared rather than being scoped to a specific episode — a sleep timer stops
// whatever's currently playing, mirroring how AudioPlayer's own play/pause commands work — and
// to SettingsClient to remember the user's last-picked duration as the new global default.
//
// @MainActor (mirroring EpisodeDetailView's own rationale) so loadDefaultDuration()'s and
// start(minutes:)'s Task {} bodies stay main-actor-isolated across their await points — without
// it, the @State writes after those awaits could run on a background executor, and AudioPlayer's
// own properties are only ever safely read/mutated on main.
@MainActor
struct SleepTimerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var audioPlayer = AudioPlayer.shared
    @State private var defaultDurationMinutes: Int?
    @State private var isLoadingDefault = false
    @State private var saveDefaultError: String?
    @State private var saveDefaultDurationTask: Task<Void, Never>?
    // Bumped on every start(minutes:) call; lets a save task tell whether it's still the latest
    // one after waiting on its predecessor, mirroring EpisodeDetailView.savePlaybackSpeed's same
    // pattern — without it, quickly tapping several presets could send overlapping PUTs whose
    // responses arrive out of order and persist an older pick as the default.
    @State private var saveDefaultDurationVersion = 0

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
    // shouldTriggerOutroSkip/EpisodeDetailView's resolvedPlaybackURL test seams. nonisolated so
    // tests (and EpisodeDetailView's own use of this from its non-MainActor-declared
    // sleepTimerButtonTitle) can call it synchronously without hopping onto the main actor —
    // it touches no actor-isolated state, so isolation would only add friction here.
    nonisolated static func formatRemaining(_ seconds: TimeInterval?) -> String? {
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
        saveDefaultDuration(minutes)
    }

    // Chains each save behind the previous one (awaiting it before sending), same rationale as
    // EpisodeDetailView.savePlaybackSpeed: the endpoint is a plain read-then-upsert, so two
    // in-flight PUTs could otherwise land out of order and leave a stale duration persisted as
    // the default. The version check after that wait coalesces away anything superseded by a
    // newer tap before it would even be sent.
    private func saveDefaultDuration(_ minutes: Int) {
        saveDefaultDurationVersion += 1
        let requestVersion = saveDefaultDurationVersion
        let previousTask = saveDefaultDurationTask
        saveDefaultDurationTask = Task {
            await previousTask?.value
            guard requestVersion == saveDefaultDurationVersion else { return }

            do {
                _ = try await settingsClient.updateSleepTimerDefaultDuration(minutes)
            } catch {
                if requestVersion == saveDefaultDurationVersion {
                    saveDefaultError = "Something went wrong while saving your default duration."
                }
            }
        }
    }
}

#Preview {
    SleepTimerSheet()
}
