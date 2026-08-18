import SwiftUI

struct ShowSettingsSheet: View {
    let showId: String
    let showTitle: String

    @Environment(\.dismiss) private var dismiss
    @State private var settings: ShowSettings?
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

        isSaving = true
        saveError = nil
        settings = ShowSettings(
            id: previous.id, userId: previous.userId, showId: previous.showId,
            unlistenedEpisodeCount: value, version: previous.version)

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

        if !Task.isCancelled {
            isSaving = false
        }
    }
}

#Preview {
    ShowSettingsSheet(showId: "preview-show", showTitle: "Preview Show")
}
