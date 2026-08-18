import SwiftUI

struct SettingsView: View {
    @State private var settings: UserSettings?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var isSaving = false
    @State private var saveError: String?
    // Cancelling the previous save when a new selection comes in (rather than dropping the new
    // one while a save is in flight) means the last value the user picked always wins, even if
    // they pick again before the prior PUT has resolved.
    @State private var saveTask: Task<Void, Never>?

    private let settingsClient = SettingsClient()

    var body: some View {
        Form {
            if let loadError {
                Text(loadError)
                    .foregroundStyle(.red)
            }

            Section {
                Picker("Unlistened episodes to show", selection: unlistenedEpisodeCountBinding) {
                    ForEach(UnlistenedEpisodeCount.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .disabled(settings == nil)
            } footer: {
                if let saveError {
                    Text(saveError)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Settings")
        .overlay {
            if isLoading && settings == nil {
                ProgressView()
            }
        }
        .task {
            await loadSettings()
        }
    }

    private var unlistenedEpisodeCountBinding: Binding<UnlistenedEpisodeCount> {
        Binding(
            get: { settings?.unlistenedEpisodeCount ?? .five },
            set: { newValue in
                saveTask?.cancel()
                saveTask = Task { await updateUnlistenedEpisodeCount(newValue) }
            }
        )
    }

    private func loadSettings() async {
        isLoading = true
        loadError = nil
        do {
            settings = try await settingsClient.getSettings()
        } catch {
            if !Task.isCancelled {
                loadError = "Something went wrong while loading your settings. Please try again."
            }
        }
        isLoading = false
    }

    private func updateUnlistenedEpisodeCount(_ value: UnlistenedEpisodeCount) async {
        guard let previous = settings else { return }

        isSaving = true
        saveError = nil
        settings = UserSettings(userId: previous.userId, unlistenedEpisodeCount: value, version: previous.version)

        do {
            let updated = try await settingsClient.updateUnlistenedEpisodeCount(value)
            if !Task.isCancelled {
                settings = updated
            }
        } catch {
            if !Task.isCancelled {
                settings = previous
                saveError = "Something went wrong while saving. Please try again."
            }
        }

        if !Task.isCancelled {
            isSaving = false
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
}
