import SwiftUI

struct ShowSettingsSheet: View {
    let showId: String
    let showTitle: String

    @Environment(\.dismiss) private var dismiss
    @State private var settings: ShowSettings?
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
        NavigationStack {
            Form {
                if let loadError {
                    Text(loadError)
                        .foregroundStyle(.red)
                }

                Section {
                    Picker("Unlistened episodes to show", selection: overrideBinding) {
                        Text("Use global default").tag(UnlistenedEpisodeCount?.none)
                        ForEach(UnlistenedEpisodeCount.allCases) { option in
                            Text(option.label).tag(UnlistenedEpisodeCount?.some(option))
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
                    Picker("Auto-archive played episodes", selection: archiveOverrideBinding) {
                        Text("Use global default").tag(AutoArchiveRule?.none)
                        ForEach(AutoArchiveRule.allCases) { option in
                            Text(option.label).tag(AutoArchiveRule?.some(option))
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
            .navigationTitle(showTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay {
                if isLoading && settings == nil {
                    ProgressView()
                }
            }
            .task {
                await loadSettings()
            }
        }
    }

    private var overrideBinding: Binding<UnlistenedEpisodeCount?> {
        Binding(
            get: { settings?.unlistenedEpisodeCount },
            set: { newValue in
                saveTask?.cancel()
                saveTask = Task { await updateOverride(newValue) }
            }
        )
    }

    private var archiveOverrideBinding: Binding<AutoArchiveRule?> {
        Binding(
            get: { settings?.autoArchiveRule },
            set: { newValue in
                archiveSaveTask?.cancel()
                archiveSaveTask = Task { await updateArchiveOverride(newValue) }
            }
        )
    }

    private func loadSettings() async {
        isLoading = true
        loadError = nil
        do {
            settings = try await settingsClient.getShowSettings(showId: showId)
        } catch {
            if !Task.isCancelled {
                loadError = "Something went wrong while loading this podcast's settings. Please try again."
            }
        }
        isLoading = false
    }

    private func updateOverride(_ value: UnlistenedEpisodeCount?) async {
        guard let previous = settings else { return }

        saveError = nil
        settings = ShowSettings(
            id: previous.id, userId: previous.userId, showId: previous.showId,
            unlistenedEpisodeCount: value, version: previous.version, autoArchiveRule: previous.autoArchiveRule)

        do {
            let updated = try await settingsClient.updateShowUnlistenedEpisodeCount(showId: showId, value: value)
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

    private func updateArchiveOverride(_ value: AutoArchiveRule?) async {
        guard let previous = settings else { return }

        archiveSaveError = nil
        settings = ShowSettings(
            id: previous.id, userId: previous.userId, showId: previous.showId,
            unlistenedEpisodeCount: previous.unlistenedEpisodeCount, version: previous.version, autoArchiveRule: value)

        do {
            let updated = try await settingsClient.updateShowAutoArchiveRule(showId: showId, value: value)
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
    ShowSettingsSheet(showId: "preview-show", showTitle: "Preview Show")
}
