import SwiftUI

struct SettingsView: View {
    @State private var settings: UserSettings?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var archiveSaveError: String?
    // Cancelling the previous save when a new selection comes in (rather than dropping the new
    // one while a save is in flight) means the last value the user picked always wins, even if
    // they pick again before the prior PUT has resolved.
    @State private var saveTask: Task<Void, Never>?
    @State private var archiveSaveTask: Task<Void, Never>?

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

            Section {
                Picker("Auto-archive played episodes", selection: autoArchiveRuleBinding) {
                    ForEach(AutoArchiveRule.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .disabled(settings == nil)
            } footer: {
                if let archiveSaveError {
                    Text(archiveSaveError)
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

    private var autoArchiveRuleBinding: Binding<AutoArchiveRule> {
        Binding(
            get: { settings?.autoArchiveRule ?? .never },
            set: { newValue in
                archiveSaveTask?.cancel()
                archiveSaveTask = Task { await updateAutoArchiveRule(newValue) }
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

        saveError = nil
        settings = UserSettings(
            userId: previous.userId, unlistenedEpisodeCount: value, version: previous.version,
            autoArchiveRule: previous.autoArchiveRule)

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
    }

    private func updateAutoArchiveRule(_ value: AutoArchiveRule) async {
        guard let previous = settings else { return }

        archiveSaveError = nil
        settings = UserSettings(
            userId: previous.userId, unlistenedEpisodeCount: previous.unlistenedEpisodeCount, version: previous.version,
            autoArchiveRule: value)

        do {
            let updated = try await settingsClient.updateAutoArchiveRule(value)
            if !Task.isCancelled {
                settings = updated
            }
        } catch {
            if !Task.isCancelled {
                settings = previous
                archiveSaveError = "Something went wrong while saving. Please try again."
            }
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
}
